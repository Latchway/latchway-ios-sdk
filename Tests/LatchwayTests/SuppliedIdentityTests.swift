import Foundation
import XCTest
@testable import Latchway
import LatchwayTesting

final class SuppliedIdentityTests: XCTestCase {
    private static let identity = LatchwaySuppliedIdentityConfiguration(
        providerID: "custom_jwt", issuer: "https://issuer.test", audience: "my-project")

    func testPureFirebaseMetadataAndConfigurationModeConflict() throws {
        let firebase = try LatchwaySuppliedIdentityConfiguration.firebaseProject(projectID: "habitify-dev")
        XCTAssertEqual(firebase.providerID, "firebase")
        XCTAssertEqual(firebase.audience, "habitify-dev")
        XCTAssertEqual(firebase.issuer, "https://securetoken.google.com/habitify-dev")
        XCTAssertThrowsError(try LatchwaySuppliedIdentityConfiguration.firebaseProject(projectID: "../bad"))
        let value = try registration()
        var options = LatchwayAppOptions(baseURL: value.baseURL, applicationID: value.applicationID,
            environment: value.environment)
        try value.compare(LatchwayAppRegistration(options), fromReactNative: true)
        options.suppliedIdentity = .init(providerID: "custom_jwt", issuer: "https://issuer.test", audience: "other")
        XCTAssertThrowsError(try value.compare(LatchwayAppRegistration(options), fromReactNative: true))
    }

    func testJWTParsingRejectsWrongIssuerAudienceTenantMalformedAndExpired() throws {
        XCTAssertNoThrow(try LatchwaySuppliedToken(Self.token("A"), configuration: Self.identity))
        for claims in [
            ["iss": "https://wrong.test", "aud": "my-project", "sub": "A", "exp": Date().timeIntervalSince1970 + 60] as [String: Any],
            ["iss": "https://issuer.test", "aud": "wrong", "sub": "A", "exp": Date().timeIntervalSince1970 + 60],
            ["iss": "https://issuer.test", "aud": "my-project", "sub": "A", "exp": true],
            ["iss": "https://issuer.test", "aud": "my-project", "sub": "A", "exp": 1],
            ["iss": "https://issuer.test", "aud": "my-project", "sub": "A", "exp": Date().timeIntervalSince1970 + 60,
             "firebase": ["tenant": "unexpected"]],
        ] {
            XCTAssertThrowsError(try LatchwaySuppliedToken(Self.encode(claims), configuration: Self.identity))
        }
        XCTAssertThrowsError(try LatchwaySuppliedToken("not-a-jwt", configuration: Self.identity))
    }

    func testMemoryStoreRequiresVerificationAndFencesStaleCommit() async throws {
        let store = LatchwaySuppliedIdentityState()
        let a = UUID(), b = UUID()
        let value = try LatchwaySuppliedToken(Self.token("A"), configuration: Self.identity)
        store.suspend(operationID: a)
        await expect(.identityRefreshRequired) { _ = try await store.identitySnapshot() }
        store.suspend(operationID: b)
        await expect(.accountChanged) { try store.commit(value, expiresAt: value.expiresAt, operationID: a) }
        try store.commit(value, expiresAt: value.expiresAt, operationID: b)
        let snapshot = try await store.identitySnapshot()
        XCTAssertEqual(snapshot?.subject, "A")
        store.clear()
        await expect(.identityRefreshRequired) { _ = try await store.identitySnapshot() }
    }

    func testSignInRefreshAndAccountSwitchUseOpaqueGenerations() async throws {
        let records = IdentityMemoryRecords()
        let app = try app(records: records)
        let a = try await app.signIn(idToken: Self.token("A"))
        let first = await app.snapshot()
        XCTAssertEqual(first.state, .active)
        try await a.updateIdToken(Self.token("A"))
        let refreshed = await app.snapshot()
        XCTAssertEqual(first.generationID, refreshed.generationID)
        await expect(.accountChanged) { try await a.updateIdToken(Self.token("B")) }
        let b = try await app.signIn(idToken: Self.token("B"))
        let next = await app.snapshot()
        XCTAssertNotEqual(first.generationID, next.generationID)
        try await a.logout()
        await assertState(app, .active)
        await expect(.loggedOut) { _ = try await a.makeClient() }
        try await b.logout()
        await assertState(app, .loggedOut)
        await expect(.loggedOut) { _ = try await app.restore(idToken: Self.token("B")) }
        let again = try await app.signIn(idToken: Self.token("B"))
        XCTAssertNotEqual(again.generationID, b.generationID)
        let persisted = try XCTUnwrap(records.read())
        XCTAssertFalse(String(decoding: persisted, as: UTF8.self).contains(Self.token("B")))
    }

    func testAppSignOutClearsSharedNativeAndReactNativeAccountAndAllowsFreshLogin() async throws {
        let records = IdentityMemoryRecords()
        let app = try app(records: records)
        let old = try await app.signIn(idToken: Self.token("A"))
        let native = try await old.makeClient(runtime: .iOS)
        let reactNative = try await old.makeClient(runtime: .reactNativeIOS)
        try await app.signOut()
        await assertState(app, .loggedOut)
        let current = try await app.currentAccount()
        XCTAssertNil(current)
        await expect(.loggedOut) { _ = try await old.makeClient() }
        let entry = try JSONDecoder().decode(LatchwayAppSessionJournal.Entry.self, from: XCTUnwrap(records.read()))
        XCTAssertNil(entry.session)
        XCTAssertNil(entry.components)
        let next = try await app.signIn(idToken: Self.token("B"))
        XCTAssertNotEqual(next.generationID, old.generationID)
        // Native/RN clients and opaque account handles retain only the old
        // generation; their delayed logout must not affect the new account.
        try await native.logout()
        try await reactNative.logout()
        try await old.logout()
        await assertState(app, .active)
        let active = try await app.currentAccount()
        XCTAssertEqual(active?.generationID, next.generationID)
        try await app.signOut()
        let sameUser = try await app.signIn(idToken: Self.token("B"))
        XCTAssertNotEqual(next.generationID, sameUser.generationID)
    }

    func testAppSignOutBeforeFirstActivationPersistsLogoutIntentAndIsIdempotent() async throws {
        let records = IdentityMemoryRecords()
        let app = try app(records: records)
        try await app.signOut()
        try await app.signOut()
        await assertState(app, .loggedOut)
        await expect(.loggedOut) { _ = try await app.restore(idToken: Self.token("A")) }
        let restarted = try self.app(records: records)
        await expect(.loggedOut) { _ = try await restarted.restore(idToken: Self.token("A")) }
        _ = try await restarted.signIn(idToken: Self.token("A"))
    }

    func testAppSignOutFencesLateFirstTokenProducerWithoutAVisibleAccount() async throws {
        let app = try app()
        let gate = IdentityGate()
        let pending = Task { try await app.signIn { await gate.wait(); return Self.token("A") } }
        await gate.started()
        let unpublished = try await app.currentAccount()
        XCTAssertNil(unpublished)
        try await app.signOut()
        let next = try await app.signIn(idToken: Self.token("B"))
        await gate.release()
        do { _ = try await pending.value; XCTFail("Late producer restored old account") } catch {}
        let current = try await app.currentAccount()
        XCTAssertEqual(current?.generationID, next.generationID)
        await assertState(app, .active)
    }

    func testAppSignOutFencesLateGatewayVerificationAndBridgeTicket() async throws {
        let gate = IdentityGate()
        let app = try app(verify: { token in
            let result = try Self.verified(token)
            if result.identity.subject == "A" { await gate.wait() }
            return result
        })
        let ticket = try await app.beginIdentity(intent: .signIn)
        let pending = Task { try await app.completeIdentity(ticketID: ticket, idToken: Self.token("A")) }
        await gate.started()
        try await app.signOut()
        let next = try await app.signIn(idToken: Self.token("B"))
        await gate.release()
        do { _ = try await pending.value; XCTFail("Late verifier restored old account") } catch {}
        try await app.cancelIdentity(ticketID: ticket)
        let current = try await app.currentAccount()
        XCTAssertEqual(current?.generationID, next.generationID)
    }

    func testAppSignOutRefreshRequiredAndFailedCleanupRetry() async throws {
        let records = IdentityMemoryRecords()
        let app = try app(records: records)
        _ = try await app.signIn(idToken: Self.token("A", expires: Date().addingTimeInterval(0.12)))
        try await Task.sleep(nanoseconds: 200_000_000)
        await assertState(app, .refreshRequired)
        records.setFailure(true)
        await expect(.cleanupRequired) { try await app.signOut() }
        await assertState(app, .retiring)
        await expect(.cleanupRequired) { _ = try await app.signIn(idToken: Self.token("B")) }
        records.setFailure(false)
        try await app.signOut()
        await assertState(app, .loggedOut)
        _ = try await app.signIn(idToken: Self.token("B"))
    }

    func testAppSignOutRetriesFailedEmptyLogoutMarker() async throws {
        let records = IdentityMemoryRecords()
        let app = try app(records: records)
        records.setFailure(true)
        await expect(.cleanupRequired) { try await app.signOut() }
        records.setFailure(false)
        try await app.signOut()
        _ = try await app.signIn(idToken: Self.token("A"))
    }

    func testAppSignOutRetiresColdPersistedAccountWithoutFetchingIdentity() async throws {
        let records = IdentityMemoryRecords()
        let registration = try registration()
        let original = try app(records: records, registration: registration)
        let old = try await original.signIn(idToken: Self.token("A"))
        let journal = LatchwayAppSessionJournal(records: records)
        try await journal.save(.init(refreshToken: "fixture-refresh", refreshExpiresAt: Date().addingTimeInterval(600),
            installation: .init(id: "ins_fixture", platform: "ios", dpopJKT: "fixture", status: "active")), generation: old.generationID)
        let restarted = try app(records: records, registration: registration,
            verify: { _ in XCTFail("Sign-out fetched identity"); throw LatchwayLifecycleError.identityUnavailable })
        await assertState(restarted, .inactive)
        try await restarted.signOut()
        let entry = try await journal.entry()
        XCTAssertEqual(entry?.state, .loggedOut)
        XCTAssertNil(entry?.session)
        await expect(.loggedOut) { _ = try await restarted.restore(idToken: Self.token("A")) }
    }

    func testAppSignOutFinishesColdRetiringAccountAndAllowsSignIn() async throws {
        let records = IdentityMemoryRecords()
        let registration = try registration()
        let original = try app(records: records, registration: registration)
        let old = try await original.signIn(idToken: Self.token("A"))
        let journal = LatchwayAppSessionJournal(records: records)
        try await journal.retire(old.generationID)
        let restarted = try app(records: records, registration: registration)
        await assertState(restarted, .retiring)
        records.setFailure(true)
        await expect(.cleanupRequired) { try await restarted.signOut() }
        records.setFailure(false)
        try await restarted.signOut()
        let next = try await restarted.signIn(idToken: Self.token("B"))
        XCTAssertNotEqual(old.generationID, next.generationID)
    }

    func testAppSignOutRetriesAfterTimedOutBackgroundCleanupHasAlreadyFinished() async throws {
        let records = IdentityMemoryRecords()
        let registration = try registration()
        let app = try app(records: records, registration: registration, cleanupTimeoutNanoseconds: 5_000_000)
        let old = try await app.signIn(idToken: Self.token("A"))
        let journal = LatchwayAppSessionJournal(records: records)
        let persisted = try await journal.entry()
        let entry = try XCTUnwrap(persisted)
        let scope = LatchwayAppIdentity.digest([registration.scope, registration.rootGroup!, entry.account])
        let fingerprint = LatchwayProcessScopeIdentity.sharedFingerprint(scope: scope, generation: old.generationID)
        let coordinator = LatchwayProcessScopeCoordinatorPool.shared.root(
            identity: LatchwayProcessScopeIdentity.sharedRoot(scope: scope, generation: old.generationID), configurationFingerprint: fingerprint)
        let permit = try await coordinator.acquire(configurationFingerprint: fingerprint)
        await expect(.cleanupRequired) { try await app.signOut() }
        await assertState(app, .retiring)
        await expect(.cleanupRequired) { _ = try await app.signIn(idToken: Self.token("B")) }
        await coordinator.release(permit)
        while try await journal.entry()?.state != .loggedOut { await Task.yield() }
        // The generation task has finished; retry must clear the app's new
        // journal fence rather than permanently blocking the next sign-in.
        try await app.signOut()
        _ = try await app.signIn(idToken: Self.token("B"))
    }

    func testConcurrentAppSignOutJoinsTheSameDrain() async throws {
        let records = IdentityMemoryRecords()
        let registration = try registration()
        let app = try LatchwayApp(registration: registration,
            attestationFactory: { _ in LatchwayFixedAttestationProvider(evidence: .init(provider: "app_attest", evidence: [:])) },
            lifecycleRecords: records, prepareAccount: { _ in }, verifyIdentity: { try Self.verified($0) })
        let old = try await app.signIn(idToken: Self.token("A"))
        let entry = try JSONDecoder().decode(LatchwayAppSessionJournal.Entry.self, from: XCTUnwrap(records.read()))
        let scope = LatchwayAppIdentity.digest([registration.scope, registration.rootGroup!, entry.account])
        let fingerprint = LatchwayProcessScopeIdentity.sharedFingerprint(scope: scope, generation: old.generationID)
        let coordinator = LatchwayProcessScopeCoordinatorPool.shared.root(
            identity: LatchwayProcessScopeIdentity.sharedRoot(scope: scope, generation: old.generationID), configurationFingerprint: fingerprint)
        let permit = try await coordinator.acquire(configurationFingerprint: fingerprint)
        let first = Task { try await app.signOut() }
        while await app.snapshot().state != .retiring { await Task.yield() }
        let second = Task { try await app.signOut() }
        await expect(.cleanupRequired) { _ = try await app.signIn(idToken: Self.token("B")) }
        await coordinator.release(permit)
        try await first.value
        try await second.value
        await assertState(app, .loggedOut)
        _ = try await app.signIn(idToken: Self.token("B"))
    }

    func testUnverifiedReplacementCannotRestoreCachedAccess() async throws {
        let verifier = IdentityVerifier()
        let app = try app(verify: { try await verifier.verify($0) })
        let account = try await app.signIn(idToken: Self.token("A"))
        await verifier.rejectNext()
        do { try await account.updateIdToken(Self.token("A", suffix: "forged")); XCTFail("Expected verification rejection") }
        catch let error as LatchwayError { XCTAssertEqual(error, .invalidServerResponse) }
        // Failed verification did not install the forged token or extend any
        // deadline. Cancellation safely resumes only the previously verified token.
        let current = try await app.currentAccount()
        XCTAssertEqual(current?.generationID, account.generationID)
    }

    func testCancelledInitialProducerCannotRestoreAfterLogoutFence() async throws {
        let records = IdentityMemoryRecords()
        let app = try app(records: records)
        let gate = IdentityGate()
        let pending = Task { try await app.signIn { await gate.wait(); return Self.token("A") } }
        await gate.started()
        pending.cancel()
        await gate.release()
        do { _ = try await pending.value; XCTFail("Expected cancellation") } catch {}
        await expect(.loggedOut) { _ = try await app.restore(idToken: Self.token("A")) }
        let restarted = try self.app(records: records)
        await expect(.loggedOut) { _ = try await restarted.restore(idToken: Self.token("A")) }
    }

    func testLateVerificationCannotCommitAfterCancel() async throws {
        let gate = IdentityGate()
        let app = try app(verify: { token in await gate.wait(); return try Self.verified(token) })
        let ticket = try await app.beginIdentity(intent: .signIn)
        let pending = Task { try await app.completeIdentity(ticketID: ticket, idToken: Self.token("A")) }
        await gate.started()
        try await app.cancelIdentity(ticketID: ticket)
        await gate.release()
        do { _ = try await pending.value; XCTFail("Late verification committed") } catch {}
        await assertState(app, .loggedOut)
    }

    func testExpirySuspendsWithoutRetiringAndVerifiedUpdateResumes() async throws {
        let app = try app()
        let account = try await app.signIn(idToken: Self.token("A", expires: Date().addingTimeInterval(0.12)))
        try await Task.sleep(nanoseconds: 200_000_000)
        await expect(.identityRefreshRequired) { _ = try await account.makeClient() }
        await assertState(app, .refreshRequired)
        try await account.updateIdToken(Self.token("A"))
        await assertState(app, .active)
        let current = try await app.currentAccount()
        XCTAssertEqual(current?.generationID, account.generationID)
    }

    func testBindingLeaseCannotBeStolenAndReleaseDoesNotLogout() async throws {
        let app = try app()
        let account = try await app.signIn(idToken: Self.token("A"))
        let a = UUID(), b = UUID()
        try await app.claimIdentityBinding(a)
        await expect(.configurationConflict) { try await app.claimIdentityBinding(b) }
        let ticket = try await app.beginIdentity(intent: .update, generationID: account.generationID, bindingID: a)
        await app.releaseIdentityBinding(a)
        await expect(.accountChanged) { _ = try await app.completeIdentity(ticketID: ticket, idToken: Self.token("A")) }
        await assertState(app, .active)
        try await app.claimIdentityBinding(b)
    }

    func testCancellingNewSignInIntentDoesNotLogoutPreviouslyPublishedAccount() async throws {
        let app = try app()
        let account = try await app.signIn(idToken: Self.token("A"))
        let bindingID = UUID()
        try await app.claimIdentityBinding(bindingID)
        let ticket = try await app.beginIdentity(intent: .signIn, bindingID: bindingID)
        await app.releaseIdentityBinding(bindingID)
        await assertState(app, .active)
        let current = try await app.currentAccount()
        XCTAssertEqual(current?.generationID, account.generationID)
        await expect(.accountChanged) { _ = try await app.completeIdentity(ticketID: ticket, idToken: Self.token("B")) }
    }

    func testCancelledJournalTicketCannotActivateAfterEmptyLogout() async throws {
        let journal = LatchwayAppSessionJournal(records: IdentityMemoryRecords())
        let ticket = UUID()
        await journal.beginIdentityOperation(ticket)
        await journal.cancelIdentityOperation(ticket)
        try await journal.recordEmptyLogout()
        await expect(.accountChanged) { _ = try await journal.activate(account: "A", identityTicket: ticket) }
        let entry = try await journal.entry()
        XCTAssertEqual(entry?.state, .loggedOut)
    }

    func testVerificationWireUsesRefreshPossessionAndFreshDPoPWithoutAccessToken() async throws {
        let transport = LatchwayScriptedTransport { request, index in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let proof = try XCTUnwrap(request.value(forHTTPHeaderField: "DPoP"))
            let payload = try Base64URL.decode(String(proof.split(separator: ".")[1]))
            let claims = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
            XCTAssertNil(claims["ath"])
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            if index == 0 {
                XCTAssertEqual(request.url?.path, "/.well-known/latchway")
                return .init(statusCode: 200, headers: ["Content-Type": "application/json"],
                    body: Data(#"{"capabilities":["supplied_identity_v1"],"identity_verification_endpoint":"/client/v1/sessions/identity"}"#.utf8))
            }
            XCTAssertEqual(request.url?.path, "/client/v1/sessions/identity")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(body["refresh_token"] as? String, "fixture-refresh-only")
            let identity = try XCTUnwrap(body["identity"] as? [String: String])
            XCTAssertEqual(identity, ["provider": "custom_jwt", "token": "fixture-id-token"])
            return .init(statusCode: 200, headers: ["Content-Type": "application/json"],
                body: Data(#"{"identity":{"provider":"custom_jwt","issuer":"https://issuer.test","subject":"A","audience":["my-project"],"verified_at":"2026-09-08T10:00:00Z","expires_at":"2026-09-08T11:00:00Z"},"installation_id":"ins_fixture"}"#.utf8))
        }
        let plane = try controlPlane(transport)
        try await plane.requireSuppliedIdentitySupport()
        let result = try await plane.verifyIdentity(refreshToken: "fixture-refresh-only", idToken: "fixture-id-token")
        XCTAssertEqual(result.identity.subject, "A")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertNotEqual(requests[0].value(forHTTPHeaderField: "DPoP"), requests[1].value(forHTTPHeaderField: "DPoP"))
    }

    func testMissingOrRedirectedVerificationCapabilityFailsExplicitly() async throws {
        for body in [#"{}"#, #"{"capabilities":["supplied_identity_v1"],"identity_verification_endpoint":"https://evil.test/identity"}"#] {
            let plane = try controlPlane(LatchwayScriptedTransport { _, _ in
                .init(statusCode: 200, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
            })
            await expect(.identityVerificationUnsupported) { try await plane.requireSuppliedIdentitySupport() }
        }
    }

    private func controlPlane(_ transport: any LatchwayHTTPTransport) throws -> LatchwayControlPlane {
        let key = try LatchwayDeterministicInstallationKey(rawPrivateKey:
            Base64URL.decode("2ZFd1bc5bCB8zu8OEf5l7O9x_SxbsQNQMNn0si4NxxI"))
        let clock = LatchwaySystemClock()
        return .init(configuration: .init(baseURL: URL(string: "https://example.test")!, applicationID: "app",
            environment: "development", rootKeychainAccessGroup: "TEAM.app", identityProvider: "custom_jwt"),
            transport: transport, proofFactory: .init(key: key, clock: clock), clock: clock)
    }

    private func registration() throws -> LatchwayAppRegistration {
        try LatchwayAppRegistration(.init(baseURL: URL(string: "https://example.test")!, applicationID: UUID().uuidString,
            environment: "development", rootKeychainAccessGroup: "TEAM.app", suppliedIdentity: Self.identity)).effective()
    }

    private func app(records: IdentityMemoryRecords = IdentityMemoryRecords(), registration: LatchwayAppRegistration? = nil,
                     cleanupTimeoutNanoseconds: UInt64 = 30_000_000_000,
                     verify: @escaping @Sendable (String) async throws -> LatchwayVerifiedIdentityWire = { try SuppliedIdentityTests.verified($0) }) throws -> LatchwayApp {
        try LatchwayApp(registration: registration ?? self.registration(),
            attestationFactory: { _ in LatchwayFixedAttestationProvider(evidence: .init(provider: "app_attest", evidence: [:])) },
            lifecycleRecords: records, prepareAccount: { _ in }, verifyIdentity: verify,
            cleanupTimeoutNanoseconds: cleanupTimeoutNanoseconds)
    }

    private static func token(_ subject: String, expires: Date = Date().addingTimeInterval(3600), suffix: String = "signature") -> String {
        encode(["iss": identity.issuer, "aud": identity.audience, "sub": subject, "exp": expires.timeIntervalSince1970], suffix: suffix)
    }
    private static func encode(_ claims: [String: Any], suffix: String = "signature") -> String {
        "eyJhbGciOiJSUzI1NiJ9." + Base64URL.encode(try! JSONSerialization.data(withJSONObject: claims)) + "." + suffix
    }
    private static func verified(_ token: String) throws -> LatchwayVerifiedIdentityWire {
        let value = try LatchwaySuppliedToken(token, configuration: identity)
        return .init(identity: .init(provider: identity.providerID, issuer: identity.issuer, subject: value.snapshot.subject,
            audience: [identity.audience], verifiedAt: Date(), expiresAt: value.expiresAt), installationID: "ins_fixture")
    }
    private func assertState(_ app: LatchwayApp, _ expected: LatchwayAppSnapshot.State) async {
        let state = await app.snapshot().state
        XCTAssertEqual(state, expected)
    }
    private func expect(_ expected: LatchwayLifecycleError, operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(expected)") }
        catch let error as LatchwayLifecycleError { XCTAssertEqual(error, expected) }
        catch { XCTFail("Unexpected error: \(error)") }
    }
}

private actor IdentityVerifier {
    private var reject = false
    func rejectNext() { reject = true }
    func verify(_ token: String) throws -> LatchwayVerifiedIdentityWire {
        if reject { reject = false; throw LatchwayError.invalidServerResponse }
        let configuration = LatchwaySuppliedIdentityConfiguration(providerID: "custom_jwt", issuer: "https://issuer.test", audience: "my-project")
        let value = try LatchwaySuppliedToken(token, configuration: configuration)
        return .init(identity: .init(provider: configuration.providerID, issuer: configuration.issuer, subject: value.snapshot.subject,
            audience: [configuration.audience], verifiedAt: Date(), expiresAt: value.expiresAt), installationID: "ins_fixture")
    }
}
private actor IdentityGate {
    private var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { waiting = true; await withCheckedContinuation { continuation = $0 } }
    func started() async { while !waiting { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}
private final class IdentityMemoryRecords: LatchwayLifecycleRecords, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    private var failWrites = false
    func read() throws -> Data? { lock.withLock { value } }
    func write(_ value: Data) throws {
        try lock.withLock {
            if failWrites { throw LatchwayLifecycleError.cleanupRequired }
            self.value = value
        }
    }
    func setFailure(_ value: Bool) { lock.withLock { failWrites = value } }
}
