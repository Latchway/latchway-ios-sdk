import Foundation
import LatchwayTesting
@testable import Latchway
import XCTest

final class ClientSessionTests: XCTestCase {
    func testConcurrentAuthorizationEstablishesOneSession() async throws {
        let fixture = try await makeFixture()
        try await withThrowingTaskGroup(of: URLRequest.self) { group in
            for _ in 0 ..< 32 {
                group.addTask {
                    var request = URLRequest(url: URL(string: "https://gateway.example.test/v1/responses")!)
                    request.httpMethod = "POST"
                    try await fixture.client.authorize(&request, feature: "habit-assistant")
                    return request
                }
            }
            var proofs = Set<String>()
            for try await request in group {
                XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("DPoP ") == true)
                proofs.insert(try XCTUnwrap(request.value(forHTTPHeaderField: "DPoP")))
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Latchway-Feature"), "habit-assistant")
            }
            XCTAssertEqual(proofs.count, 32, "Every request requires a unique DPoP jti")
        }
        let counts = await fixture.server.counts()
        let identityCount = await fixture.identity.count()
        let attestationCount = await fixture.attestation.challenges.count
        XCTAssertEqual(counts.challenge, 1)
        XCTAssertEqual(counts.exchange, 1)
        XCTAssertEqual(identityCount, 1)
        XCTAssertEqual(attestationCount, 1)
    }

    func testExpiredAccessTokenRefreshesOnceAcrossConcurrentCallers() async throws {
        let fixture = try await makeFixture()
        var first = URLRequest(url: URL(string: "https://gateway.example.test/v1/responses")!)
        try await fixture.client.authorize(&first, feature: "habit-assistant")
        await fixture.clock.advance(by: 3_601)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 24 {
                group.addTask {
                    var request = URLRequest(url: URL(string: "https://gateway.example.test/v1/responses")!)
                    try await fixture.client.authorize(&request, feature: "habit-assistant")
                }
            }
            try await group.waitForAll()
        }
        let counts = await fixture.server.counts()
        let saveCount = await fixture.storage.saveCount
        XCTAssertEqual(counts.challenge, 1)
        XCTAssertEqual(counts.exchange, 1)
        XCTAssertEqual(counts.refresh, 1)
        XCTAssertEqual(saveCount, 2)
    }

    func testExpiredCallersRecheckSessionAfterActorReentrancy() async throws {
        let fixture = try await makeFixture()
        var first = URLRequest(url: URL(string: "https://gateway.example.test/v1/responses")!)
        try await fixture.client.authorize(&first, feature: "habit-assistant")
        await fixture.clock.advance(by: 3_601)
        await fixture.clock.suspendReads()

        let callers = (0 ..< 24).map { _ in
            Task {
                var request = URLRequest(url: URL(string: "https://gateway.example.test/v1/responses")!)
                try await fixture.client.authorize(&request, feature: "habit-assistant")
            }
        }

        for _ in 0 ..< 10_000 {
            if await fixture.clock.pendingReadCount() == callers.count { break }
            await Task.yield()
        }
        let allCallersSuspended = await fixture.clock.pendingReadCount() == callers.count
        await fixture.clock.resumeOneReadAndAllowFutureReads()

        var firstRefreshCompleted = false
        for _ in 0 ..< 10_000 {
            let counts = await fixture.server.counts()
            if counts.refresh == 1, await fixture.storage.saveCount == 2 {
                firstRefreshCompleted = true
                break
            }
            await Task.yield()
        }
        await fixture.clock.resumePendingReads()
        for caller in callers { try await caller.value }

        XCTAssertTrue(allCallersSuspended)
        XCTAssertTrue(firstRefreshCompleted)
        let counts = await fixture.server.counts()
        let saveCount = await fixture.storage.saveCount
        XCTAssertEqual(counts.challenge, 1)
        XCTAssertEqual(counts.exchange, 1)
        XCTAssertEqual(counts.refresh, 1)
        XCTAssertEqual(saveCount, 2)
    }

    func testDPoPNonceChallengeRetriesControlRequestOnlyOnce() async throws {
        let fixture = try await makeFixture(requireNonce: true)
        var request = URLRequest(url: URL(string: "https://gateway.example.test/v1/responses")!)
        try await fixture.client.authorize(&request, feature: "habit-assistant")
        let counts = await fixture.server.counts()
        XCTAssertEqual(counts.challenge, 2)
        XCTAssertEqual(counts.exchange, 1)
        let proofs = await fixture.server.challengeProofs()
        let requestIDs = await fixture.server.challengeRequestIDs()
        XCTAssertEqual(proofs.count, 2)
        XCTAssertNotEqual(proofs[0], proofs[1])
        XCTAssertEqual(requestIDs[0], requestIDs[1])
        let secondPayload = try proofPayload(proofs[1])
        XCTAssertEqual(secondPayload["nonce"] as? String, "nonce-fixture-0123456789abcdef")
    }

    func testControlPlaneDoesNotRetryAmbiguousDPoPNonce() async throws {
        let fixture = try await makeFixture(
            requireNonce: true,
            safeRetryProblemMutation: .commaNonce
        )
        var request = URLRequest(url: URL(string: "https://gateway.example.test/v1/responses")!)

        await XCTAssertThrowsErrorAsync {
            try await fixture.client.authorize(&request, feature: "habit-assistant")
        }

        let counts = await fixture.server.counts()
        XCTAssertEqual(counts.challenge, 1)
        XCTAssertEqual(counts.exchange, 0)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testCancellationDoesNotReturnAuthorizedSecretHeaders() async throws {
        let fixture = try await makeFixture(delayNanoseconds: 250_000_000)
        let task = Task { () throws -> URLRequest in
            var request = URLRequest(url: URL(string: "https://gateway.example.test/v1/responses")!)
            try await fixture.client.authorize(&request, feature: "habit-assistant")
            return request
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do {
            let request = try await task.value
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTFail("Cancellation must fail before returning an authorized request")
        } catch let error as LatchwayError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    func testRejectsCredentialLeakAndForeignOrigin() async throws {
        let fixture = try await makeFixture()
        var credential = URLRequest(url: URL(string: "https://gateway.example.test/v1/responses")!)
        credential.setValue("provider-secret", forHTTPHeaderField: "X-Api-Key")
        await XCTAssertThrowsErrorAsync { try await fixture.client.authorize(&credential, feature: "habit-assistant") }

        var queryCredential = URLRequest(
            url: URL(string: "https://gateway.example.test/v1/responses?api_key=provider-secret")!
        )
        await XCTAssertThrowsErrorAsync {
            try await fixture.client.authorize(&queryCredential, feature: "habit-assistant")
        }

        var invalidRequestID = URLRequest(
            url: URL(string: "https://gateway.example.test/v1/responses")!
        )
        invalidRequestID.setValue("bad id", forHTTPHeaderField: "X-Latchway-Request-ID")
        await XCTAssertThrowsErrorAsync {
            try await fixture.client.authorize(&invalidRequestID, feature: "habit-assistant")
        }

        var foreign = URLRequest(url: URL(string: "https://attacker.example/v1/responses")!)
        await XCTAssertThrowsErrorAsync { try await fixture.client.authorize(&foreign, feature: "habit-assistant") }
        XCTAssertNil(foreign.value(forHTTPHeaderField: "Authorization"))
    }

    func testRejectsEveryKnownProviderCredentialAliasBeforeControlPlaneUse() async throws {
        let fixture = try await makeFixture()
        let credentialNames = [
            "authorization", "proxy-authorization",
            "api-key", "api_key", "apikey", "x-api-key",
            "openai-api-key", "openai_api_key", "x-openai-api-key",
            "anthropic-api-key", "anthropic_api_key",
            "access_token", "auth_token", "token", "key", "x-auth-token", "cookie",
            "x-amz-credential", "x-amz-security-token", "x-amz-signature",
            "x-goog-api-key", "x-goog_api_key", "x-goog-credential", "x-goog-signature",
        ]

        for name in credentialNames {
            var request = URLRequest(url: URL(string: "https://gateway.example.test/v1/responses")!)
            request.setValue("provider-secret", forHTTPHeaderField: name.uppercased())
            await XCTAssertThrowsErrorAsync {
                try await fixture.client.authorize(&request, feature: "habit-assistant")
            }
            XCTAssertNil(request.value(forHTTPHeaderField: "DPoP"), "Header alias must fail before signing: \(name)")
        }

        for name in credentialNames {
            let uppercased = name.uppercased()
            let first = try XCTUnwrap(uppercased.utf8.first)
            let encodedName = String(format: "%%%02X", first) + uppercased.dropFirst()
            var request = URLRequest(
                url: try XCTUnwrap(URL(string: "https://gateway.example.test/v1/responses?\(encodedName)=provider-secret"))
            )
            await XCTAssertThrowsErrorAsync {
                try await fixture.client.authorize(&request, feature: "habit-assistant")
            }
            XCTAssertNil(request.value(forHTTPHeaderField: "DPoP"), "Query alias must fail before signing: \(name)")
        }

        var multiplyEncoded = URLRequest(
            url: URL(string: "https://gateway.example.test/v1/responses?api%255Fkey=provider-secret")!
        )
        await XCTAssertThrowsErrorAsync {
            try await fixture.client.authorize(&multiplyEncoded, feature: "habit-assistant")
        }

        let counts = await fixture.server.counts()
        XCTAssertEqual(counts.challenge, 0)
        XCTAssertEqual(counts.refresh, 0)
        XCTAssertEqual(counts.dataPlane, 0)
    }

    func testOrdinaryQueryIsAuthorizedAndCookiesRemainDisabled() async throws {
        let fixture = try await makeFixture()
        var request = URLRequest(
            url: URL(string: "https://gateway.example.test/v1/responses?cursor=next-page&include=usage")!
        )

        try await fixture.client.authorize(&request, feature: "habit-assistant")

        XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
        let configuration = await fixture.client.makeURLSession().configuration
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
    }

    func testRejectsNormalizedTraversalOutsideConfiguredBasePath() async throws {
        let fixture = try await makeFixture(
            baseURL: URL(string: "https://gateway.example.test/gateway")!
        )
        var request = URLRequest(
            url: URL(string: "https://gateway.example.test/gateway/%2e%2e/admin")!
        )
        await XCTAssertThrowsErrorAsync {
            try await fixture.client.authorize(&request, feature: "habit-assistant")
        }
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let counts = await fixture.server.counts()
        XCTAssertEqual(counts.challenge, 0)
    }

    func testExpiredChallengeFailsBeforeAttestationOrExchange() async throws {
        let fixture = try await makeFixture(challengeExpired: true)
        var request = URLRequest(url: URL(string: "https://gateway.example.test/v1/responses")!)
        do {
            try await fixture.client.authorize(&request, feature: "habit-assistant")
            XCTFail("Expired challenge must fail closed")
        } catch let error as LatchwayError {
            XCTAssertEqual(error, .invalidAttestationBinding)
        }
        let counts = await fixture.server.counts()
        let attestationCount = await fixture.attestation.challenges.count
        XCTAssertEqual(counts.exchange, 0)
        XCTAssertEqual(attestationCount, 0)
    }

    func testServerClientDataHashIsPassedDirectlyToAttestationProvider() async throws {
        let fixture = try await makeFixture()
        var request = URLRequest(url: URL(string: "https://gateway.example.test/v1/responses")!)

        try await fixture.client.authorize(&request, feature: "habit-assistant")

        let challenges = await fixture.attestation.challenges
        let challenge = try XCTUnwrap(challenges.first)
        XCTAssertEqual(challenge.clientDataHash, Data(repeating: 7, count: 32))
        XCTAssertNil(challenge.options["principal_id"])
    }

    func testChallengeBeyondAllowedClockSkewFailsClosed() async throws {
        let fixture = try await makeFixture(challengeClockOffset: 301)
        var request = URLRequest(url: URL(string: "https://gateway.example.test/v1/responses")!)
        do {
            try await fixture.client.authorize(&request, feature: "habit-assistant")
            XCTFail("A future-issued challenge beyond the skew allowance must fail")
        } catch let error as LatchwayError {
            XCTAssertEqual(error, .invalidAttestationBinding)
        }
        let counts = await fixture.server.counts()
        let attestationCount = await fixture.attestation.challenges.count
        XCTAssertEqual(counts.exchange, 0)
        XCTAssertEqual(attestationCount, 0)
    }

    func testRefreshIdentityReauthenticationStartsFreshAttestedExchange() async throws {
        let fixture = try await makeFixture(refreshRejection: "identity_reauthentication_required")
        var first = URLRequest(url: URL(string: "https://gateway.example.test/v1/responses")!)
        try await fixture.client.authorize(&first, feature: "habit-assistant")
        try await fixture.client.refresh()
        var second = URLRequest(url: URL(string: "https://gateway.example.test/v1/responses")!)
        try await fixture.client.authorize(&second, feature: "habit-assistant")
        let counts = await fixture.server.counts()
        let identityCount = await fixture.identity.count()
        let attestationCount = await fixture.attestation.challenges.count
        let refreshBodyFields = await fixture.server.refreshBodyFields()
        XCTAssertEqual(counts.refresh, 1)
        XCTAssertEqual(counts.challenge, 2)
        XCTAssertEqual(counts.exchange, 2)
        XCTAssertEqual(identityCount, 2)
        XCTAssertEqual(attestationCount, 2)
        XCTAssertEqual(refreshBodyFields, [["refresh_token"]])
    }

    func testRefreshAttestationStepUpStartsFreshAttestedExchange() async throws {
        let fixture = try await makeFixture(refreshRejection: "attestation_step_up_required")
        var first = URLRequest(url: URL(string: "https://gateway.example.test/v1/responses")!)
        try await fixture.client.authorize(&first, feature: "habit-assistant")
        try await fixture.client.refresh()
        var second = URLRequest(url: URL(string: "https://gateway.example.test/v1/responses")!)
        try await fixture.client.authorize(&second, feature: "habit-assistant")

        let counts = await fixture.server.counts()
        let attestationCount = await fixture.attestation.challenges.count
        let refreshBodyFields = await fixture.server.refreshBodyFields()
        XCTAssertEqual(counts.refresh, 1)
        XCTAssertEqual(counts.challenge, 2)
        XCTAssertEqual(counts.exchange, 2)
        XCTAssertEqual(attestationCount, 2)
        XCTAssertEqual(refreshBodyFields, [["refresh_token"]])
    }

    func testFailedRefreshStepUpReplacementCannotReuseRetiredSession() async throws {
        let fixture = try await makeFixture(
            refreshRejection: "attestation_step_up_required",
            failSecondAttestation: true
        )
        var first = URLRequest(url: URL(string: "https://gateway.example.test/v1/responses")!)
        try await fixture.client.authorize(&first, feature: "habit-assistant")

        do {
            try await fixture.client.refresh()
            XCTFail("A failed attested replacement must fail closed")
        } catch let error as LatchwayError {
            XCTAssertEqual(error, .attestationUnavailable)
        }
        let failedDiagnostics = await fixture.client.diagnostics()
        let retiredStorage = try await fixture.storage.load()
        XCTAssertNil(failedDiagnostics.sessionExpiresAt)
        XCTAssertNil(retiredStorage)

        var recovered = URLRequest(url: URL(string: "https://gateway.example.test/v1/responses")!)
        try await fixture.client.authorize(&recovered, feature: "habit-assistant")
        let counts = await fixture.server.counts()
        XCTAssertEqual(counts.refresh, 1)
        XCTAssertEqual(counts.challenge, 3)
        XCTAssertEqual(counts.exchange, 2)
    }

    func testRefreshTokenReuseClearsRotatedState() async throws {
        let fixture = try await makeFixture(refreshRejection: "refresh_token_reused")
        var first = URLRequest(url: URL(string: "https://gateway.example.test/v1/responses")!)
        try await fixture.client.authorize(&first, feature: "habit-assistant")
        await fixture.clock.advance(by: 3_601)
        var second = URLRequest(url: URL(string: "https://gateway.example.test/v1/responses")!)
        do {
            try await fixture.client.authorize(&second, feature: "habit-assistant")
            XCTFail("Reused refresh token must fail")
        } catch let LatchwayError.server(problem) {
            XCTAssertEqual(problem.code, .refreshTokenReused)
        }
        let clearCount = await fixture.storage.clearCount
        XCTAssertEqual(clearCount, 1)
    }

    func testFailedRotatedTokenPersistenceCannotReplayOldRefreshToken() async throws {
        let fixture = try await makeFixture(failingSaveCalls: [2])
        var first = URLRequest(url: URL(string: "https://gateway.example.test/v1/responses")!)
        try await fixture.client.authorize(&first, feature: "habit-assistant")
        await fixture.clock.advance(by: 3_601)

        var second = URLRequest(url: URL(string: "https://gateway.example.test/v1/responses")!)
        do {
            try await fixture.client.authorize(&second, feature: "habit-assistant")
            XCTFail("The unsaved rotated session must fail")
        } catch let error as LatchwayError {
            XCTAssertEqual(error, .keyStorageFailure)
        }

        await fixture.clock.set(Date(timeIntervalSince1970: 1_700_000_000))
        var recovered = URLRequest(url: URL(string: "https://gateway.example.test/v1/responses")!)
        try await fixture.client.authorize(&recovered, feature: "habit-assistant")
        let counts = await fixture.server.counts()
        XCTAssertEqual(counts.refresh, 1, "The consumed refresh token must never be retried")
        XCTAssertEqual(counts.challenge, 2)
        XCTAssertEqual(counts.exchange, 2)
    }

    func testCorruptPersistedRefreshStateIsClearedBeforeNetworkUse() async throws {
        let fixture = try await makeFixture(storedRefreshToken: "short")
        var request = URLRequest(url: URL(string: "https://gateway.example.test/v1/responses")!)

        try await fixture.client.authorize(&request, feature: "habit-assistant")

        let counts = await fixture.server.counts()
        let clearCount = await fixture.storage.clearCount
        XCTAssertEqual(counts.refresh, 0)
        XCTAssertEqual(counts.challenge, 1)
        XCTAssertEqual(counts.exchange, 1)
        XCTAssertEqual(clearCount, 1)
    }

    func testServerRevokedInstallationBlocksFurtherSessionUse() async throws {
        let fixture = try await makeFixture(refreshRejection: "installation_revoked")
        var first = URLRequest(url: URL(string: "https://gateway.example.test/v1/responses")!)
        try await fixture.client.authorize(&first, feature: "habit-assistant")
        await fixture.clock.advance(by: 3_601)
        var second = URLRequest(url: URL(string: "https://gateway.example.test/v1/responses")!)
        await XCTAssertThrowsErrorAsync { try await fixture.client.authorize(&second, feature: "habit-assistant") }
        let before = await fixture.server.counts()
        var third = URLRequest(url: URL(string: "https://gateway.example.test/v1/responses")!)
        await XCTAssertThrowsErrorAsync { try await fixture.client.authorize(&third, feature: "habit-assistant") }
        let after = await fixture.server.counts()
        let diagnostics = await fixture.client.diagnostics()
        XCTAssertEqual(before.challenge, after.challenge)
        XCTAssertEqual(before.refresh, after.refresh)
        XCTAssertEqual(diagnostics.sessionState, .revoked)
    }

    func testQuotaAndExplicitRevocationUseProtectedControlEndpoints() async throws {
        let fixture = try await makeFixture()
        let quota = try await fixture.client.quota(feature: "habit-assistant")
        XCTAssertEqual(quota.feature, "habit-assistant")
        XCTAssertEqual(quota.limits.first?.remaining, 4)
        try await fixture.client.revokeCurrentInstallation()
        let counts = await fixture.server.counts()
        let clearCount = await fixture.storage.clearCount
        let resetCount = await fixture.attestation.resetCount
        let diagnostics = await fixture.client.diagnostics()
        XCTAssertEqual(counts.quota, 1)
        XCTAssertEqual(counts.revoke, 1)
        XCTAssertEqual(clearCount, 1)
        XCTAssertEqual(resetCount, 1)
        XCTAssertEqual(diagnostics.sessionState, .revoked)
        await XCTAssertThrowsErrorAsync { try await fixture.client.refresh() }
        let countsAfterRefresh = await fixture.server.counts()
        XCTAssertEqual(countsAfterRefresh.challenge, counts.challenge)
        XCTAssertEqual(countsAfterRefresh.refresh, counts.refresh)
    }

    func testBufferedSendRetriesSessionExpiryOnceBeforeDispatch() async throws {
        let fixture = try await makeFixture(dataPlaneRejection: "session_expired")
        var request = URLRequest(url: URL(string: "https://gateway.example.test/v1/responses")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        let response = try await fixture.client.send(request, feature: "habit-assistant")
        XCTAssertEqual(response.statusCode, 200)
        let counts = await fixture.server.counts()
        XCTAssertEqual(counts.dataPlane, 2)
        XCTAssertEqual(counts.refresh, 1)
    }

    func testBufferedSendDoesNotRetrySessionExpiryWithoutRetryGuidance() async throws {
        let fixture = try await makeFixture(
            dataPlaneRejection: "session_expired",
            dataPlaneRetryable: false
        )
        let request = URLRequest(url: URL(string: "https://gateway.example.test/v1/responses")!)
        do {
            _ = try await fixture.client.send(request, feature: "habit-assistant")
            XCTFail("A non-retryable problem must not be replayed")
        } catch let LatchwayError.server(problem) {
            XCTAssertEqual(problem.code, .sessionExpired)
            XCTAssertFalse(problem.retryable)
        }
        let counts = await fixture.server.counts()
        XCTAssertEqual(counts.dataPlane, 1)
        XCTAssertEqual(counts.refresh, 0)
    }

    func testBufferedSendRetriesDPoPNonceOnceWithoutRefreshing() async throws {
        let fixture = try await makeFixture(dataPlaneRejection: "dpop_nonce_required")
        let request = URLRequest(url: URL(string: "https://gateway.example.test/v1/responses")!)
        let response = try await fixture.client.send(request, feature: "habit-assistant")
        XCTAssertEqual(response.statusCode, 200)
        let counts = await fixture.server.counts()
        let proofs = await fixture.server.dataPlaneProofs()
        let requestIDs = await fixture.server.dataPlaneRequestIDs()
        XCTAssertEqual(counts.dataPlane, 2)
        XCTAssertEqual(counts.refresh, 0)
        XCTAssertEqual(requestIDs[0], requestIDs[1])
        XCTAssertEqual(try proofPayload(proofs[1])["nonce"] as? String, "nonce-fixture-0123456789abcdef")
    }

    func testBufferedSendRequiresCanonicalSafeRetryProblemBeforeReplay() async throws {
        let cases: [(String, SafeRetryProblemMutation)] = [
            ("missing member", .missingMember),
            ("extra member", .extraMember),
            ("wrong type", .wrongType),
            ("wrong title", .wrongTitle),
            ("wrong detail", .wrongDetail),
            ("wrong status", .wrongStatus),
            ("missing request ID header", .missingRequestIDHeader),
            ("wrong request ID", .wrongRequestID),
            ("non-retryable", .notRetryable),
            ("duplicate member", .duplicateMember),
            ("Unicode duplicate member", .unicodeDuplicateMember),
            ("missing nonce", .missingNonce),
            ("comma-joined nonce", .commaNonce),
            ("whitespace nonce", .whitespaceNonce),
            ("control nonce", .controlNonce),
            ("non-ASCII nonce", .nonASCIINonce),
            ("duplicate nonce header", .duplicateNonceHeader),
        ]

        for (label, mutation) in cases {
            let fixture = try await makeFixture(
                dataPlaneRejection: "dpop_nonce_required",
                safeRetryProblemMutation: mutation
            )
            var request = URLRequest(url: URL(string: "https://gateway.example.test/v1/responses")!)
            request.setValue("request-retry-0001", forHTTPHeaderField: "X-Latchway-Request-ID")

            do {
                _ = try await fixture.client.send(request, feature: "habit-assistant")
                XCTFail("Unsafe retry metadata must not cause replay: \(label)")
            } catch {}

            let counts = await fixture.server.counts()
            XCTAssertEqual(counts.dataPlane, 1, label)
            XCTAssertEqual(counts.refresh, 0, label)
        }
    }

    func testBufferedSendRejectsSessionRetryWhenNonceHeaderIsPresent() async throws {
        let fixture = try await makeFixture(
            dataPlaneRejection: "session_expired",
            safeRetryProblemMutation: .sessionNonce
        )
        var request = URLRequest(url: URL(string: "https://gateway.example.test/v1/responses")!)
        request.setValue("request-retry-0001", forHTTPHeaderField: "X-Latchway-Request-ID")

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.client.send(request, feature: "habit-assistant")
        }

        let counts = await fixture.server.counts()
        XCTAssertEqual(counts.dataPlane, 1)
        XCTAssertEqual(counts.refresh, 0)
    }

    func testBufferedSendNeverRetriesAmbiguousUpstreamFailure() async throws {
        let fixture = try await makeFixture(dataPlaneRejection: "upstream_unavailable")
        let request = URLRequest(url: URL(string: "https://gateway.example.test/v1/responses")!)
        do {
            _ = try await fixture.client.send(request, feature: "habit-assistant")
            XCTFail("Ambiguous upstream failure must not be replayed")
        } catch let LatchwayError.server(problem) {
            XCTAssertEqual(problem.code, .upstreamUnavailable)
        }
        let counts = await fixture.server.counts()
        let diagnostics = await fixture.client.diagnostics()
        XCTAssertEqual(counts.dataPlane, 1)
        XCTAssertEqual(counts.refresh, 0)
        XCTAssertEqual(diagnostics.sessionState, .active)
        XCTAssertEqual(diagnostics.lastErrorCode, "upstream_unavailable")
    }

    func testBufferedSendPreservesIndeterminateOperationIDWithoutRetry() async throws {
        let operationID = "arq_0123456789ABCDEFGHJKMNPQRS"
        let fixture = try await makeFixture(
            dataPlaneRejection: "operation_indeterminate",
            dataPlaneOperationID: operationID
        )
        let request = URLRequest(url: URL(string: "https://gateway.example.test/v1/responses")!)

        do {
            _ = try await fixture.client.send(request, feature: "habit-assistant")
            XCTFail("An indeterminate operation must be returned for reconciliation")
        } catch let LatchwayError.server(problem) {
            XCTAssertEqual(problem.code, .operationIndeterminate)
            XCTAssertEqual(problem.operationID, operationID)
            XCTAssertEqual(problem.status, 503)
            XCTAssertTrue(problem.retryable)
        }

        let counts = await fixture.server.counts()
        XCTAssertEqual(counts.dataPlane, 1)
        XCTAssertEqual(counts.refresh, 0)
    }

    func testBufferedSendRejectsMissingMalformedOrForbiddenOperationID() async throws {
        let canonical = "arq_0123456789ABCDEFGHJKMNPQRS"
        let cases: [(code: String, operationID: String?)] = [
            ("operation_indeterminate", nil),
            ("operation_indeterminate", "identity-token-reflection"),
            ("upstream_unavailable", canonical),
        ]

        for testCase in cases {
            let fixture = try await makeFixture(
                dataPlaneRejection: testCase.code,
                dataPlaneOperationID: testCase.operationID
            )
            let request = URLRequest(url: URL(string: "https://gateway.example.test/v1/responses")!)

            do {
                _ = try await fixture.client.send(request, feature: "habit-assistant")
                XCTFail("Invalid operation_id semantics must fail closed")
            } catch let error as LatchwayError {
                XCTAssertEqual(error, .invalidServerResponse)
                if let operationID = testCase.operationID {
                    XCTAssertFalse(error.description.contains(operationID))
                }
            }
        }
    }

    func testBufferedSendRejectsMalformedErrorWithoutRetry() async throws {
        let fixture = try await makeFixture(dataPlaneRejection: "malformed")
        let request = URLRequest(url: URL(string: "https://gateway.example.test/v1/responses")!)
        do {
            _ = try await fixture.client.send(request, feature: "habit-assistant")
            XCTFail("A malformed gateway error must fail closed")
        } catch let error as LatchwayError {
            XCTAssertEqual(error, .invalidServerResponse)
        }
        let counts = await fixture.server.counts()
        XCTAssertEqual(counts.dataPlane, 1)
        XCTAssertEqual(counts.refresh, 0)
    }

    func testStreamingPathAuthorizesWithoutDispatchOrAutomaticReplay() async throws {
        let fixture = try await makeFixture(dataPlaneRejection: "upstream_unavailable")
        var request = URLRequest(url: URL(string: "https://gateway.example.test/v1/responses")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"stream":true}"#.utf8)

        try await fixture.client.authorize(&request, feature: "habit-assistant")

        let counts = await fixture.server.counts()
        XCTAssertEqual(counts.dataPlane, 0, "Streaming dispatch belongs to the caller's URLSession")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "DPoP"))
        XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testReactNativeRuntimeUsesPairedSDKAndPlatformIdentifiers() async throws {
        let fixture = try await makeFixture(
            clientRuntime: .reactNativeIOS,
            clientSDKVersion: "0.1.0-dev.0"
        )
        var request = URLRequest(url: URL(string: "https://gateway.example.test/v1/responses")!)

        try await fixture.client.authorize(&request, feature: "habit-assistant")

        let challengeSDKIdentifiers = await fixture.server.challengeSDKIdentifiers()
        let challengePlatforms = await fixture.server.challengePlatforms()
        let challengeSDKVersions = await fixture.server.challengeSDKVersions()
        let diagnostics = await fixture.client.diagnostics()
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Latchway-SDK"), "react-native")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Latchway-SDK-Version"), "0.1.0-dev.0")
        XCTAssertEqual(challengeSDKIdentifiers, ["react-native"])
        XCTAssertEqual(challengePlatforms, ["react_native_ios"])
        XCTAssertEqual(challengeSDKVersions, ["0.1.0-dev.0"])
        XCTAssertEqual(diagnostics.sdkVersion, "0.1.0-dev.0")
        XCTAssertEqual(diagnostics.trustProvider, "app_attest")
        XCTAssertEqual(diagnostics.trustLevel, "app_verified")
    }

    func testCallerOwnedTransportCanAuthorizeNonceRetry() async throws {
        let fixture = try await makeFixture()
        var request = URLRequest(url: URL(string: "https://gateway.example.test/v1/responses")!)

        try await fixture.client.authorize(
            &request,
            feature: "habit-assistant",
            nonce: "nonce-fixture-0123456789abcdef"
        )

        let proof = try XCTUnwrap(request.value(forHTTPHeaderField: "DPoP"))
        XCTAssertEqual(
            try proofPayload(proof)["nonce"] as? String,
            "nonce-fixture-0123456789abcdef"
        )
    }

    func testCallerOwnedTransportCanForceSingleFlightRefresh() async throws {
        let fixture = try await makeFixture()
        var request = URLRequest(url: URL(string: "https://gateway.example.test/v1/responses")!)
        try await fixture.client.authorize(&request, feature: "habit-assistant")

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 16 {
                group.addTask { try await fixture.client.refresh() }
            }
            try await group.waitForAll()
        }

        let counts = await fixture.server.counts()
        XCTAssertEqual(counts.refresh, 1)
    }

    func testCallerOwnedTransportRejectsInvalidNonceBeforeSigning() async throws {
        let fixture = try await makeFixture()
        let invalidNonces = [
            "short",
            "nonce with whitespace 0123456789",
            "nonce,joined-0123456789",
            "nonce\twith-tab-0123456789",
            "nön-ascii-nonce-0123456789",
            String(repeating: "n", count: 513),
        ]

        for nonce in invalidNonces {
            var request = URLRequest(url: URL(string: "https://gateway.example.test/v1/responses")!)
            do {
                try await fixture.client.authorize(&request, feature: "habit-assistant", nonce: nonce)
                XCTFail("An invalid server nonce must fail before authorization")
            } catch let LatchwayError.invalidRequest(reason) {
                XCTAssertTrue(reason.contains("nonce"))
            }
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        }
        let counts = await fixture.server.counts()
        XCTAssertEqual(counts.challenge, 0)
    }

    func testInvalidClientSDKVersionFailsBeforeNetworkUse() async throws {
        let fixture = try await makeFixture(clientSDKVersion: "development")
        var request = URLRequest(url: URL(string: "https://gateway.example.test/v1/responses")!)

        do {
            try await fixture.client.authorize(&request, feature: "habit-assistant")
            XCTFail("An invalid SDK version must fail before session establishment")
        } catch let LatchwayError.invalidConfiguration(reason) {
            XCTAssertTrue(reason.contains("clientSDKVersion"))
        }
        let counts = await fixture.server.counts()
        XCTAssertEqual(counts.challenge, 0)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testNoncanonicalApplicationIDsFailBeforeNetworkUse() async throws {
        for applicationID in [
            "habitify",
            "app_habitify",
            "app_81J00000000000000000000000",
            "app_01j00000000000000000000000",
            "app_01J0000000000000000000000",
        ] {
            let fixture = try await makeFixture(applicationID: applicationID)
            var request = URLRequest(url: URL(string: "https://gateway.example.test/v1/responses")!)
            do {
                try await fixture.client.authorize(&request, feature: "habit-assistant")
                XCTFail("A noncanonical application ID must fail locally")
            } catch let LatchwayError.invalidConfiguration(reason) {
                XCTAssertTrue(reason.contains("applicationID"))
            }
            let counts = await fixture.server.counts()
            XCTAssertEqual(counts.challenge, 0)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        }
    }

    private struct Fixture {
        let client: LatchwayClient
        let server: SessionServerTransport
        let identity: CountingIdentityProvider
        let attestation: LatchwayScriptedAttestationProvider
        let storage: LatchwayInMemorySessionStorage
        let clock: LatchwayTestClock
    }

    private func makeFixture(
        requireNonce: Bool = false,
        delayNanoseconds: UInt64 = 0,
        dataPlaneRejection: String? = nil,
        dataPlaneRetryable: Bool = true,
        dataPlaneOperationID: String? = nil,
        safeRetryProblemMutation: SafeRetryProblemMutation? = nil,
        challengeExpired: Bool = false,
        challengeClockOffset: TimeInterval = 0,
        refreshRejection: String? = nil,
        failSecondAttestation: Bool = false,
        failingSaveCalls: Set<Int> = [],
        storedRefreshToken: String? = nil,
        applicationID: String = "app_01J00000000000000000000000",
        clientRuntime: LatchwayClientRuntime = .iOS,
        clientSDKVersion: String = LatchwayVersion.sdk,
        baseURL: URL = URL(string: "https://gateway.example.test")!
    ) async throws -> Fixture {
        let raw = try decodeBase64URL("2ZFd1bc5bCB8zu8OEf5l7O9x_SxbsQNQMNn0si4NxxI")
        let key = try LatchwayDeterministicInstallationKey(rawPrivateKey: raw)
        let clock = LatchwayTestClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let thumbprint = try await LatchwayDPoPProofFactory(key: key, clock: clock).thumbprint()
        let server = SessionServerTransport(
            thumbprint: thumbprint,
            now: Date(timeIntervalSince1970: 1_700_000_000),
            requireNonce: requireNonce,
            delayNanoseconds: delayNanoseconds,
            dataPlaneRejection: dataPlaneRejection,
            dataPlaneRetryable: dataPlaneRetryable,
            dataPlaneOperationID: dataPlaneOperationID,
            safeRetryProblemMutation: safeRetryProblemMutation,
            challengeExpired: challengeExpired,
            challengeClockOffset: challengeClockOffset,
            refreshRejection: refreshRejection,
            platform: clientRuntime.platformIdentifier
        )
        let identity = CountingIdentityProvider(token: String(repeating: "i", count: 32))
        let evidence = LatchwayAttestationEvidence(provider: "app_attest", evidence: [
            "key_id": .string("fixture-key"),
            "attestation_object": .string("YXR0ZXN0YXRpb24"),
        ])
        var attestationResults = Array(repeating: Result<LatchwayAttestationEvidence, Error>.success(evidence), count: 4)
        if failSecondAttestation {
            attestationResults[1] = .failure(LatchwayError.attestationUnavailable)
        }
        let attestation = LatchwayScriptedAttestationProvider(results: attestationResults)
        let storedSession = storedRefreshToken.map { token in
            LatchwayStoredSession(
                refreshToken: token,
                refreshExpiresAt: Date(timeIntervalSince1970: 1_700_086_400),
                installation: LatchwayInstallationSummary(
                    id: "ins_01J00000000000000000000000",
                    platform: clientRuntime.platformIdentifier,
                    dpopJKT: thumbprint,
                    status: "active"
                )
            )
        }
        let storage = LatchwayInMemorySessionStorage(
            session: storedSession,
            failingSaveCalls: failingSaveCalls
        )
        let configuration = LatchwayConfiguration(
            baseURL: baseURL,
            applicationID: applicationID,
            environment: "production",
            clientRuntime: clientRuntime,
            clientSDKVersion: clientSDKVersion,
            appVersion: "1.2.3",
            attestationProvider: attestation
        )
        let client = LatchwayClient(
            configuration: configuration,
            identityTokenProvider: identity,
            attestationProvider: attestation,
            installationKey: key,
            sessionStorage: storage,
            transport: server,
            clock: clock
        )
        return Fixture(client: client, server: server, identity: identity, attestation: attestation, storage: storage, clock: clock)
    }

    private func proofPayload(_ proof: String) throws -> [String: Any] {
        let parts = proof.split(separator: ".")
        guard parts.count == 3 else { throw LatchwayError.dpopTestFailure }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: decodeBase64URL(String(parts[1]))) as? [String: Any])
    }

    private func decodeBase64URL(_ value: String) throws -> Data {
        var value = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        return try XCTUnwrap(Data(base64Encoded: value))
    }
}

private enum SafeRetryProblemMutation: Sendable, Equatable {
    case missingMember
    case extraMember
    case wrongType
    case wrongTitle
    case wrongDetail
    case wrongStatus
    case missingRequestIDHeader
    case wrongRequestID
    case notRetryable
    case duplicateMember
    case unicodeDuplicateMember
    case missingNonce
    case commaNonce
    case whitespaceNonce
    case controlNonce
    case nonASCIINonce
    case duplicateNonceHeader
    case sessionNonce
}

private actor CountingIdentityProvider: LatchwayIdentityTokenProvider {
    private let token: String
    private var calls = 0
    init(token: String) { self.token = token }
    func identityToken() async throws -> String {
        calls += 1
        return token
    }
    func count() -> Int { calls }
}

private actor SessionServerTransport: LatchwayHTTPTransport {
    private let thumbprint: String
    private let now: Date
    private let requireNonce: Bool
    private let delayNanoseconds: UInt64
    private var challengeCount = 0
    private var exchangeCount = 0
    private var refreshCount = 0
    private var quotaCount = 0
    private var revokeCount = 0
    private var dataPlaneCount = 0
    private var proofs: [String] = []
    private var protectedProofs: [String] = []
    private var challengeIDs: [String] = []
    private var challengeSDKs: [String] = []
    private var requestedPlatforms: [String] = []
    private var requestedSDKVersions: [String] = []
    private var refreshBodies: [[String]] = []
    private var protectedRequestIDs: [String] = []
    private let dataPlaneRejection: String?
    private let dataPlaneRetryable: Bool
    private let dataPlaneOperationID: String?
    private let safeRetryProblemMutation: SafeRetryProblemMutation?
    private let challengeExpired: Bool
    private let challengeClockOffset: TimeInterval
    private let refreshRejection: String?
    private let platform: String

    init(
        thumbprint: String,
        now: Date,
        requireNonce: Bool,
        delayNanoseconds: UInt64,
        dataPlaneRejection: String?,
        dataPlaneRetryable: Bool,
        dataPlaneOperationID: String?,
        safeRetryProblemMutation: SafeRetryProblemMutation?,
        challengeExpired: Bool,
        challengeClockOffset: TimeInterval,
        refreshRejection: String?,
        platform: String
    ) {
        self.thumbprint = thumbprint
        self.now = now
        self.requireNonce = requireNonce
        self.delayNanoseconds = delayNanoseconds
        self.dataPlaneRejection = dataPlaneRejection
        self.dataPlaneRetryable = dataPlaneRetryable
        self.dataPlaneOperationID = dataPlaneOperationID
        self.safeRetryProblemMutation = safeRetryProblemMutation
        self.challengeExpired = challengeExpired
        self.challengeClockOffset = challengeClockOffset
        self.refreshRejection = refreshRejection
        self.platform = platform
    }

    func send(_ request: URLRequest) async throws -> LatchwayHTTPResponse {
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        let path = request.url?.path ?? ""
        switch path {
        case "/client/v1/session-challenges":
            challengeCount += 1
            proofs.append(request.value(forHTTPHeaderField: "DPoP") ?? "")
            challengeIDs.append(request.value(forHTTPHeaderField: "X-Latchway-Request-ID") ?? "")
            challengeSDKs.append(request.value(forHTTPHeaderField: "X-Latchway-SDK") ?? "")
            if let body = request.httpBody,
               let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let requestedPlatform = object["platform"] as? String {
                requestedPlatforms.append(requestedPlatform)
                if let requestedSDKVersion = object["sdk_version"] as? String {
                    requestedSDKVersions.append(requestedSDKVersion)
                }
            }
            if requireNonce, challengeCount == 1 {
                return safeRetryProblem(
                    code: "dpop_nonce_required",
                    requestID: request.value(forHTTPHeaderField: "X-Latchway-Request-ID") ?? "",
                    mutation: safeRetryProblemMutation
                )
            }
            return json(status: 201, object: [
                "challenge_id": "chl_01J00000000000000000000000",
                "challenge_nonce": String(repeating: "A", count: 43),
                "binding_version": 1,
                "issued_at": Int(now.addingTimeInterval(challengeClockOffset).timeIntervalSince1970),
                "expires_at": iso(now.addingTimeInterval(challengeExpired ? -1 : challengeClockOffset + 300)),
                "attestation": [
                    "provider": "app_attest",
                    "mode": "required",
                    "client_data_hash": base64URL(Data(repeating: 7, count: 32)),
                    "provider_options": [:],
                ],
            ])
        case "/client/v1/sessions":
            exchangeCount += 1
            return grant(status: 201, sequence: exchangeCount)
        case "/client/v1/sessions/refresh":
            refreshCount += 1
            if let body = request.httpBody,
               let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                refreshBodies.append(object.keys.sorted())
            }
            if let refreshRejection, refreshCount == 1 {
                let status = refreshRejection == "installation_revoked" ? 403 : 401
                return problem(status: status, code: refreshRejection, retryable: false)
            }
            return grant(status: 200, sequence: 100 + refreshCount)
        case "/client/v1/features/habit-assistant/quota":
            quotaCount += 1
            return json(status: 200, object: [
                "feature": "habit-assistant",
                "observed_at": iso(now),
                "limits": [["metric": "logical_requests", "maximum": 5, "used": 1, "reserved": 0, "remaining": 4, "hard": true]],
            ])
        case "/client/v1/installations/current":
            revokeCount += 1
            return LatchwayHTTPResponse(statusCode: 204, headers: [:], body: Data())
        case "/client/v1/diagnostics":
            return json(status: 200, object: [
                "request_id": "request-12345678",
                "server_version": "1.0.0",
                "contract_version": "0.5.1",
                "protocol_version": 1,
                "installation": installation,
                "session": ["expires_at": iso(now.addingTimeInterval(600)), "refresh_available": true],
                // Deliberately stronger than the accepted grant. Diagnostics
                // must report the trust bound to the active session instead.
                "trust": [
                    "provider": "app_attest",
                    "level": "device_verified",
                    "verified_at": iso(now),
                    "expires_at": iso(now.addingTimeInterval(86_400)),
                ],
            ])
        case "/v1/responses":
            dataPlaneCount += 1
            protectedProofs.append(request.value(forHTTPHeaderField: "DPoP") ?? "")
            protectedRequestIDs.append(request.value(forHTTPHeaderField: "X-Latchway-Request-ID") ?? "")
            if dataPlaneCount == 1, let dataPlaneRejection {
                if dataPlaneRejection == "malformed" {
                    return LatchwayHTTPResponse(
                        statusCode: 500,
                        headers: ["Content-Type": "text/plain"],
                        body: Data("unsafe error".utf8)
                    )
                }
                let status = ["operation_indeterminate", "upstream_unavailable"]
                    .contains(dataPlaneRejection) ? 503 : 401
                if ["dpop_nonce_required", "session_expired"].contains(dataPlaneRejection) {
                    return safeRetryProblem(
                        code: dataPlaneRejection,
                        requestID: request.value(forHTTPHeaderField: "X-Latchway-Request-ID") ?? "",
                        retryable: dataPlaneRetryable,
                        mutation: safeRetryProblemMutation
                    )
                }
                let headers = dataPlaneRejection == "dpop_nonce_required"
                    ? ["DPoP-Nonce": "nonce-fixture-0123456789abcdef"]
                    : [:]
                return problem(
                    status: status,
                    code: dataPlaneRejection,
                    retryable: dataPlaneRetryable,
                    operationID: dataPlaneOperationID,
                    headers: headers
                )
            }
            return json(status: 200, object: ["ok": true])
        default:
            return problem(status: 404, code: "feature_not_found", retryable: false)
        }
    }

    func counts() -> (challenge: Int, exchange: Int, refresh: Int, quota: Int, revoke: Int, dataPlane: Int) {
        (challengeCount, exchangeCount, refreshCount, quotaCount, revokeCount, dataPlaneCount)
    }
    func refreshBodyFields() -> [[String]] { refreshBodies }

    func challengeProofs() -> [String] { proofs }
    func challengeRequestIDs() -> [String] { challengeIDs }
    func challengeSDKIdentifiers() -> [String] { challengeSDKs }
    func challengePlatforms() -> [String] { requestedPlatforms }
    func challengeSDKVersions() -> [String] { requestedSDKVersions }
    func dataPlaneProofs() -> [String] { protectedProofs }
    func dataPlaneRequestIDs() -> [String] { protectedRequestIDs }

    private func grant(status: Int, sequence: Int) -> LatchwayHTTPResponse {
        json(status: status, object: [
            "access_token": String(repeating: "a", count: 80) + String(sequence),
            "token_type": "DPoP",
            "expires_in": 600,
            "refresh_token": String(repeating: "r", count: 48) + String(sequence),
            "refresh_expires_in": 86_400,
            "installation": installation,
            "trust": trust,
        ])
    }

    private var installation: [String: Any] {
        ["id": "ins_01J00000000000000000000000", "platform": platform, "dpop_jkt": thumbprint, "status": "active"]
    }

    private var trust: [String: Any] {
        ["provider": "app_attest", "level": "app_verified", "verified_at": iso(now), "expires_at": iso(now.addingTimeInterval(86_400))]
    }

    private func problem(
        status: Int,
        code: String,
        retryable: Bool,
        operationID: String? = nil,
        headers: [String: String] = [:]
    ) -> LatchwayHTTPResponse {
        var object: [String: Any] = [
            "type": "https://latchway.dev/problems/\(code)",
            "title": "Safe failure",
            "status": status,
            "detail": "The request was rejected safely.",
            "code": code,
            "request_id": "request-12345678",
            "retryable": retryable,
        ]
        object["operation_id"] = operationID
        return json(status: status, object: object, headers: headers)
    }

    private func safeRetryProblem(
        code: String,
        requestID: String,
        retryable: Bool = true,
        mutation: SafeRetryProblemMutation? = nil
    ) -> LatchwayHTTPResponse {
        let isNonce = code == "dpop_nonce_required"
        var status = 401
        var object: [String: Any] = [
            "type": "https://latchway.dev/problems/\(code)",
            "title": isNonce ? "DPoP nonce required" : "Session expired",
            "status": status,
            "detail": isNonce
                ? "A fresh server DPoP nonce is required."
                : "The Latchway session is expired.",
            "code": code,
            "request_id": requestID,
            "retryable": retryable,
        ]
        var headers = [
            "Content-Type": "application/problem+json",
            "X-Latchway-Request-ID": requestID,
        ]
        if isNonce { headers["DPoP-Nonce"] = "nonce-fixture-0123456789abcdef" }

        switch mutation {
        case .missingMember:
            object.removeValue(forKey: "detail")
        case .extraMember:
            object["extra"] = true
        case .wrongType:
            object["type"] = "https://latchway.dev/problems/session_expired"
        case .wrongTitle:
            object["title"] = "Retry request"
        case .wrongDetail:
            object["detail"] = "Retry this request safely."
        case .wrongStatus:
            status = 400
            object["status"] = 400
        case .missingRequestIDHeader:
            headers.removeValue(forKey: "X-Latchway-Request-ID")
        case .wrongRequestID:
            object["request_id"] = "request-retry-other"
            headers["X-Latchway-Request-ID"] = "request-retry-other"
        case .notRetryable:
            object["retryable"] = false
        case .missingNonce:
            headers.removeValue(forKey: "DPoP-Nonce")
        case .commaNonce:
            headers["DPoP-Nonce"] = "nonce-first-0123456789,nonce-second-0123456789"
        case .whitespaceNonce:
            headers["DPoP-Nonce"] = "nonce with whitespace 0123456789"
        case .controlNonce:
            headers["DPoP-Nonce"] = "nonce-control-0123456789\u{7F}"
        case .nonASCIINonce:
            headers["DPoP-Nonce"] = "nön-ascii-nonce-0123456789"
        case .duplicateNonceHeader:
            headers["dpop-nonce"] = "second-nonce-0123456789"
        case .sessionNonce:
            headers["DPoP-Nonce"] = "nonce-fixture-0123456789abcdef"
        case .duplicateMember, .unicodeDuplicateMember, nil:
            break
        }

        if mutation == .duplicateMember || mutation == .unicodeDuplicateMember {
            let duplicateName = mutation == .duplicateMember ? "code" : #"co\u0064e"#
            let body = """
            {"type":"https://latchway.dev/problems/dpop_nonce_required","title":"DPoP nonce required","status":401,"detail":"A fresh server DPoP nonce is required.","code":"dpop_nonce_required","\(duplicateName)":"dpop_nonce_required","request_id":"\(requestID)","retryable":true}
            """
            return LatchwayHTTPResponse(statusCode: status, headers: headers, body: Data(body.utf8))
        }

        return LatchwayHTTPResponse(
            statusCode: status,
            headers: headers,
            body: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )
    }

    private func json(status: Int, object: Any, headers: [String: String] = [:]) -> LatchwayHTTPResponse {
        var headers = headers
        headers["Content-Type"] = status >= 400 ? "application/problem+json" : "application/json"
        return LatchwayHTTPResponse(statusCode: status, headers: headers, body: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

private extension LatchwayError {
    static var dpopTestFailure: LatchwayError { .invalidServerResponse }
}

private func XCTAssertThrowsErrorAsync(
    _ operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
