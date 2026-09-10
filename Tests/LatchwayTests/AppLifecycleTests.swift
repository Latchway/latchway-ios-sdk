import Foundation
import XCTest
@testable import Latchway
import LatchwayTesting

final class AppLifecycleTests: XCTestCase {
    func testComponentGroupsAreImmutableAndOmissionInheritsNativeOwner() throws {
        let base = URL(string: "https://example.test")!
        let registered = try LatchwayAppRegistration(.init(baseURL: base,
            applicationID: "app", environment: "dev", rootKeychainAccessGroup: "TEAM.root",
            suppliedIdentity: .init(providerID: "custom_jwt", issuer: "https://issuer.test", audience: "test"), componentKeychainAccessGroups: ["TEAM.widget"])).effective()
        let omitted = try LatchwayAppRegistration(.init(baseURL: base, applicationID: "app", environment: "dev"))
        try registered.compare(omitted, fromReactNative: true)
        let different = try LatchwayAppRegistration(.init(baseURL: base,
            applicationID: "app", environment: "dev", componentKeychainAccessGroups: ["TEAM.other"]))
        XCTAssertThrowsError(try registered.compare(different, fromReactNative: true))
        XCTAssertThrowsError(try LatchwayRootKeychainPreflight.validateAccessGroups(
            rootKeychainAccessGroup: "TEAM.root", componentKeychainAccessGroups: ["TEAM.root"]))
    }
    func testCanonicalRegistrationRetainsPathAndInheritsOmittedValues() throws {
        var options = LatchwayAppOptions(baseURL: URL(string: "https://EXAMPLE.test:443/gateway/")!,
            applicationID: "habitify", environment: "production", rootKeychainAccessGroup: "TEAM.app",
            suppliedIdentity: .init(providerID: "custom_jwt", issuer: "https://issuer.test", audience: "test"))
        let registered = try LatchwayAppRegistration(options).effective()
        XCTAssertEqual(registered.baseURL.absoluteString, "https://example.test/gateway")
        let repeated = try LatchwayAppRegistration(.init(baseURL: URL(string: "https://example.test/gateway")!,
            applicationID: "habitify", environment: "production"))
        try registered.compare(repeated, fromReactNative: true)
        options.identityProvider = "different_provider"
        XCTAssertThrowsError(try registered.compare(LatchwayAppRegistration(options), fromReactNative: false))
        let otherPath = try LatchwayAppRegistration(.init(baseURL: URL(string: "https://example.test/other")!,
            applicationID: "habitify", environment: "production"))
        XCTAssertNotEqual(otherPath.scope, registered.scope)
    }

    func testAmbiguousGatewayPathsAreRejected() {
        for path in ["/a/../b", "/a/%2E%2e/b", "/a%2Fb", "/a//b", "/a%5Cb"] {
            XCTAssertThrowsError(try LatchwayAppIdentity.canonicalURL(URL(string: "https://example.test\(path)")!))
        }
    }

    func testRetirementDurablyBlocksOldGenerationAfterRestart() async throws {
        let records = LifecycleMemoryRecords()
        let journal = LatchwayAppSessionJournal(records: records)
        let old = try await journal.activate(account: "A")
        try await journal.retire(old.generation)
        await expect(.cleanupRequired) { _ = try await journal.activate(account: "B") }
        let restarted = LatchwayAppSessionJournal(records: records)
        await expect(.loggedOut) { try await restarted.check(old.generation) }
        await expect(.cleanupRequired) { _ = try await restarted.activate(account: "B") }
        try await restarted.finishRetirement(old.generation)
        let next = try await restarted.activate(account: "B")
        XCTAssertNotEqual(old.generation, next.generation)
        await expect(.loggedOut) { try await restarted.check(old.generation) }
    }

    func testLateLogoutCannotBlockNewGeneration() async throws {
        let journal = LatchwayAppSessionJournal(records: LifecycleMemoryRecords())
        let old = try await journal.activate(account: "A")
        try await journal.retire(old.generation)
        try await journal.finishRetirement(old.generation)
        let next = try await journal.activate(account: "A")
        try await journal.retire(old.generation)
        try await journal.finishRetirement(old.generation)
        try await journal.check(next.generation)
    }

    func testFailedFenceWriteBlocksUntilCleanupRetry() async throws {
        let records = LifecycleMemoryRecords()
        let journal = LatchwayAppSessionJournal(records: records)
        let old = try await journal.activate(account: "A")
        records.setFailure(true)
        await expect(.cleanupRequired) { try await journal.retire(old.generation) }
        records.setFailure(false)
        await expect(.cleanupRequired) { try await journal.check(old.generation) }
        await expect(.cleanupRequired) { _ = try await journal.activate(account: "B") }
        try await journal.retire(old.generation)
        try await journal.finishRetirement(old.generation)
        _ = try await journal.activate(account: "B")
    }

    func testSnapshotBindingIncludesIssuerTenantAndSubject() throws {
        let a = LatchwayIdentitySnapshot(issuer: "issuer", tenant: "one", subject: "A", token: "secret")
        let b = LatchwayIdentitySnapshot(issuer: "issuer", tenant: "one", subject: "B", token: "secret")
        XCTAssertNotEqual(try a.binding(expectedIssuer: "issuer", expectedTenant: "one"),
                          try b.binding(expectedIssuer: "issuer", expectedTenant: "one"))
        XCTAssertThrowsError(try a.binding(expectedIssuer: "issuer", expectedTenant: "two"))
        XCTAssertThrowsError(try a.binding(expectedIssuer: "other", expectedTenant: "one"))
    }

    func testCleanupDeadlineRemainsFencedAndJoinsOneBackgroundCleanup() async throws {
        let journal = LatchwayAppSessionJournal(records: LifecycleMemoryRecords())
        let entry = try await journal.activate(account: "A")
        let gate = CleanupTestGate()
        let generation = LatchwayAccountGeneration(entry: entry, scope: "scope", issuer: "issuer", tenant: nil,
            identityState: TestIdentityState { XCTFail("Logout fetched identity"); return nil },
            journal: journal, cleanupTimeoutNanoseconds: 5_000_000, cleanup: { await gate.wait() })
        await expect(.cleanupRequired) { try await generation.logout() }
        await expect(.cleanupRequired) { _ = try await journal.activate(account: "B") }
        await expect(.loggedOut) { try await generation.check() }
        await gate.release()
        try await generation.logout()
        let count = await gate.calls
        XCTAssertEqual(count, 1)
        _ = try await journal.activate(account: "B")
    }

    func testClientCleanupObservesDurableRetirementAndClearsSuppliedToken() async throws {
        let journal = LatchwayAppSessionJournal(records: LifecycleMemoryRecords())
        let entry = try await journal.activate(account: "A")
        let generation = LatchwayAccountGeneration(entry: entry, scope: "scope", issuer: "issuer", tenant: nil,
            identityState: TestIdentityState { nil }, journal: journal, cleanup: {})
        let token = LatchwayOneShotTokenProvider(token: "fixture-token")
        let client = LatchwayClient(configuration: .init(baseURL: URL(string: "https://example.test")!,
            applicationID: "app", environment: "dev", rootKeychainAccessGroup: "TEAM.app"), identityTokenProvider: token,
            attestationProvider: LatchwayFixedAttestationProvider(evidence: .init(provider: "app_attest", evidence: [:])),
            installationKey: try LatchwayDeterministicInstallationKey(rawPrivateKey: Data(repeating: 1, count: 32)),
            sessionStorage: LatchwayInMemorySessionStorage(),
            transport: LatchwayScriptedTransport { _, _ in throw LatchwayLifecycleError.loggedOut },
            clock: LatchwaySystemClock())
        try await generation.registerClientCleanup(for: client) { [weak client] in
            let persisted = try? await journal.entry()
            XCTAssertEqual(persisted?.state, .retiring)
            XCTAssertNil(persisted?.session)
            await client?.clearAccountCredentials()
        }
        try await generation.logout()
        XCTAssertThrowsError(try token.identityToken())
    }

    func testIdentityLossIsDurablyFencedBeforeReturningAndCannotRestoreA() async throws {
        let records = LifecycleMemoryRecords()
        let journal = LatchwayAppSessionJournal(records: records)
        let binding = try LatchwayIdentitySnapshot(issuer: "issuer", subject: "A", token: "token")
            .binding(expectedIssuer: "issuer", expectedTenant: nil)
        let entry = try await journal.activate(account: binding)
        let generation = LatchwayAccountGeneration(entry: entry, scope: "scope", issuer: "issuer", tenant: nil,
            identityState: TestIdentityState { .init(issuer: "issuer", subject: "B", token: "token") },
            journal: journal, cleanup: {})
        await expect(.accountChanged) { _ = try await generation.identityToken() }
        await expect(.loggedOut) { try generation.checkLive() }
        let restarted = LatchwayAppSessionJournal(records: records)
        await expect(.loggedOut) { try await restarted.check(entry.generation) }
        try await generation.logout()
    }

    func testClientLeaseDisposalDoesNotCloseSiblingLease() async throws {
        let first = LatchwayClientLease()
        let sibling = LatchwayClientLease()
        let cancelled = CleanupTestGate()
        _ = try await first.register { Task { await cancelled.release() } }
        await first.close()
        await expect(.disposed) { try first.check() }
        await expect(.disposed) { _ = try await first.register {} }
        try sibling.check()
        await cancelled.wait()
    }

    func testKeyRetentionRetriesInterruptedEvictionWithoutAdoptingOldKeys() async throws {
        let records = LifecycleMemoryRecords()
        let operations = KeyEvictionLog()
        let retention = LatchwayAccountKeyRetention(records: records, limit: 2) { try await operations.evict($0) }
        let a = String(repeating: "a", count: 64)
        let b = String(repeating: "b", count: 64)
        let c = String(repeating: "c", count: 64)
        try await retention.prepare(a)
        try await retention.prepare(b)
        await operations.failNext()
        await expect(.cleanupRequired) { try await retention.prepare(c) }
        let restarted = LatchwayAccountKeyRetention(records: records, limit: 2) { try await operations.evict($0) }
        try await restarted.prepare(c)
        let removed = await operations.scopes
        XCTAssertEqual(removed, [a, a])
        try await restarted.prepare(b)
        let unchanged = await operations.scopes
        XCTAssertEqual(removed, unchanged)
    }

    func testOversizedAndDuplicatePendingKeyIndexesFailWithoutErasure() async throws {
        let scope = String(repeating: "a", count: 64)
        for encoded in [String(repeating: " ", count: 16_385),
                        "{\"version\":1,\"retained\":[],\"evicting\":[\"\(scope)\",\"\(scope)\"]}"] {
            let records = LifecycleMemoryRecords()
            try records.write(Data(encoded.utf8))
            let retention = LatchwayAccountKeyRetention(records: records) { _ in XCTFail("Must not erase keys") }
            await expect(.cleanupRequired) { try await retention.prepare(scope) }
        }
    }

    func testBufferedBytesAreFencedByLogoutAndLeaseClose() async throws {
        let journal = LatchwayAppSessionJournal(records: LifecycleMemoryRecords())
        let entry = try await journal.activate(account: "A")
        let generation = LatchwayAccountGeneration(entry: entry, scope: "scope", issuer: "issuer", tenant: nil,
            identityState: TestIdentityState { XCTFail("Stream check fetched identity"); return nil },
            journal: journal, cleanup: {})
        let first = LatchwayClientLease()
        let sibling = LatchwayClientLease()
        let data = LatchwayAsyncBytes(buffered: Data([1, 2, 3])).withGeneration(generation)
        var a = data.withLease(first).makeAsyncIterator()
        var b = data.withLease(sibling).makeAsyncIterator()
        let initial = try await a.next()
        XCTAssertEqual(initial, 1)
        await first.close()
        await expect(.disposed) { _ = try await a.next() }
        let siblingByte = try await b.next()
        XCTAssertEqual(siblingByte, 1)
        try await generation.logout()
        await expect(.loggedOut) { _ = try await b.next() }
        var restoredIterator = data.withLease(sibling).makeAsyncIterator()
        await expect(.loggedOut) { _ = try await restoredIterator.next() }
    }

    private func expect(_ expected: LatchwayLifecycleError, operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(expected)") }
        catch let error as LatchwayLifecycleError { XCTAssertEqual(error, expected) }
        catch { XCTFail("Unexpected error: \(error)") }
    }
}

private actor KeyEvictionLog {
    var scopes: [String] = []
    private var fail = false
    func failNext() { fail = true }
    func evict(_ scope: String) throws {
        scopes.append(scope)
        if fail { fail = false; throw LatchwayError.keyStorageFailure }
    }
}

private actor CleanupTestGate {
    var calls = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        calls += 1
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

/// All mutable state is protected by the same lock; synchronous methods model
/// atomic Keychain commits without depending on signed-host entitlements.
private final class LifecycleMemoryRecords: LatchwayLifecycleRecords, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    private var fail = false
    func setFailure(_ failure: Bool) { lock.withLock { fail = failure } }
    func read() throws -> Data? { lock.withLock { value } }
    func write(_ data: Data) throws {
        try lock.withLock {
            if fail { throw LatchwayError.keyStorageFailure }
            value = data
        }
    }
}
