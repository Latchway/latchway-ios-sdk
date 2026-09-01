import Foundation
import LatchwayTesting
@testable import Latchway
import XCTest

final class ComponentSessionTests: XCTestCase {
    func testSeparateExtensionClientsCoordinateProvisioningAndRefresh() async throws {
        let fixture = try await makeSharedComponentFixture(kind: .provisioningGrant)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for client in fixture.clients {
                group.addTask {
                    var request = URLRequest(
                        url: URL(string: "https://gateway.example.test/v1/responses")!
                    )
                    request.httpMethod = "POST"
                    try await client.authorize(&request, feature: "habit-assistant")
                }
            }
            try await group.waitForAll()
        }
        let establishmentCount = await fixture.server.requestCount(
            path: "/client/v1/component-sessions"
        )
        XCTAssertEqual(establishmentCount, 1)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for client in fixture.clients {
                group.addTask { try await client.refresh() }
            }
            try await group.waitForAll()
        }
        let refreshCount = await fixture.server.requestCount(
            path: "/client/v1/sessions/refresh"
        )
        let saveCount = await fixture.storage.saveCount
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(saveCount, 2)
    }

    func testSeparateExtensionClientsCoordinateDirectAttestationProviders() async throws {
        let fixture = try await makeSharedDirectAttestationFixture()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for client in fixture.clients {
                group.addTask {
                    try await client.establishDirectAttestationForContractConformance()
                }
            }
            try await group.waitForAll()
        }

        let componentBase = "/client/v1/installation-families/current/components/"
            + "cmp_01J00000000000000000000000"
        let refreshCount = await fixture.server.requestCount(
            path: "/client/v1/sessions/refresh"
        )
        let challengeCount = await fixture.server.requestCount(
            path: componentBase + "/attestation-challenges"
        )
        let exchangeCount = await fixture.server.requestCount(
            path: componentBase + "/attestation-exchanges"
        )
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(challengeCount, 1)
        XCTAssertEqual(exchangeCount, 1)
        var providerChallengeCount = 0
        for provider in fixture.providers {
            providerChallengeCount += await provider.challenges.count
        }
        XCTAssertEqual(providerChallengeCount, 1)
        let stored = await fixture.storage.load()
        XCTAssertEqual(stored?.trustSource, .delegatedDirectAttested)
    }

    func testExtensionConsumesOnlyItsProvisioningGrantAndAddsFrameworkMetadata() async throws {
        let fixture = try await makeFixture(kind: .provisioningGrant)
        let transport = fixture.client.transport(
            feature: "habit-assistant",
            framework: .swiftOpenAI(version: "4.6.0")
        )
        var request = URLRequest(
            url: URL(string: "https://gateway.example.test/v1/responses")!
        )
        request.httpMethod = "POST"
        request.setValue(
            "Bearer \(LatchwayFeatureTransport.placeholderAPIKey)",
            forHTTPHeaderField: "Authorization"
        )

        let authorized = try await transport.authorize(request)

        XCTAssertTrue(authorized.value(forHTTPHeaderField: "Authorization")?.hasPrefix("DPoP ") == true)
        XCTAssertFalse(authorized.value(forHTTPHeaderField: "Authorization")?.contains("latchway-managed") == true)
        XCTAssertEqual(authorized.value(forHTTPHeaderField: "X-Latchway-Feature"), "habit-assistant")
        XCTAssertEqual(authorized.value(forHTTPHeaderField: "X-Latchway-Framework"), "swift-openai")
        XCTAssertEqual(authorized.value(forHTTPHeaderField: "X-Latchway-Framework-Version"), "4.6.0")
        let proof = try XCTUnwrap(authorized.value(forHTTPHeaderField: "DPoP"))
        let payload = try proofPayload(proof)
        XCTAssertEqual(payload["htu"] as? String, "https://gateway.example.test/v1/responses")
        XCTAssertNotNil(payload["ath"])
        XCTAssertNil((try proofHeader(proof))["d"])

        let requests = await fixture.server.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url?.path, "/client/v1/component-sessions")
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertNotNil(requests[0].value(forHTTPHeaderField: "DPoP"))
        let stored = await fixture.storage.load()
        XCTAssertEqual(stored?.kind, .sessionRefreshToken)
        XCTAssertEqual(stored?.rotationToken, String(repeating: "r", count: 64))
    }

    func testConcurrentExtensionCallersCreateOneComponentSession() async throws {
        let fixture = try await makeFixture(kind: .provisioningGrant)
        try await withThrowingTaskGroup(of: URLRequest.self) { group in
            for _ in 0 ..< 24 {
                group.addTask {
                    var request = URLRequest(
                        url: URL(string: "https://gateway.example.test/v1/responses")!
                    )
                    request.httpMethod = "POST"
                    try await fixture.client.authorize(&request, feature: "habit-assistant")
                    return request
                }
            }
            var proofs = Set<String>()
            for try await request in group {
                proofs.insert(try XCTUnwrap(request.value(forHTTPHeaderField: "DPoP")))
            }
            XCTAssertEqual(proofs.count, 24)
        }
        let requestCount = await fixture.server.requestCount(path: "/client/v1/component-sessions")
        let saveCount = await fixture.storage.saveCount
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(saveCount, 1)
    }

    func testCancelledExtensionCallerNeverReceivesAuthorizedRequest() async throws {
        let fixture = try await makeFixture(
            kind: .provisioningGrant,
            serverDelay: .milliseconds(100)
        )
        let task = Task { () throws -> URLRequest in
            var request = URLRequest(
                url: URL(string: "https://gateway.example.test/v1/responses")!
            )
            request.httpMethod = "POST"
            try await fixture.client.authorize(&request, feature: "habit-assistant")
            return request
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled caller must not receive attached credentials")
        } catch let error as LatchwayError {
            XCTAssertEqual(error, .cancelled)
        }

        var next = URLRequest(
            url: URL(string: "https://gateway.example.test/v1/responses")!
        )
        next.httpMethod = "POST"
        try await fixture.client.authorize(&next, feature: "habit-assistant")
        XCTAssertNotNil(next.value(forHTTPHeaderField: "DPoP"))
        let exchanges = await fixture.server.requestCount(path: "/client/v1/component-sessions")
        XCTAssertEqual(exchanges, 1)
    }

    func testComponentRefreshPersistenceFailureRetriesExactTuple() async throws {
        let fixture = try await makeFixture(
            kind: .sessionRefreshToken,
            failingSaveCalls: [1]
        )
        var first = URLRequest(
            url: URL(string: "https://gateway.example.test/v1/responses")!
        )
        first.httpMethod = "POST"
        do {
            try await fixture.client.authorize(&first, feature: "habit-assistant")
            XCTFail("The rotated response must not escape before persistence")
        } catch let error as LatchwayError {
            XCTAssertEqual(error, .keyStorageFailure)
        }

        var recovered = URLRequest(
            url: URL(string: "https://gateway.example.test/v1/responses")!
        )
        recovered.httpMethod = "POST"
        try await fixture.client.authorize(&recovered, feature: "habit-assistant")

        let refreshes = await fixture.server.requests(path: "/client/v1/sessions/refresh")
        XCTAssertEqual(refreshes.count, 2)
        XCTAssertEqual(refreshes[0].httpBody, refreshes[1].httpBody)
        XCTAssertNotEqual(
            refreshes[0].value(forHTTPHeaderField: "DPoP"),
            refreshes[1].value(forHTTPHeaderField: "DPoP")
        )
        let bodies = try refreshes.map { request -> [String: String] in
            try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
        }
        XCTAssertEqual(bodies.map { $0["refresh_token"] }, [
            String(repeating: "s", count: 64),
            String(repeating: "s", count: 64),
        ])
        let saveCount = await fixture.storage.saveCount
        let persisted = await fixture.storage.load()
        XCTAssertEqual(saveCount, 2)
        XCTAssertEqual(persisted?.rotationToken, String(repeating: "r", count: 64))
    }

    func testComponentRefreshRejectsMismatchedInstallationBinding() async throws {
        let fixture = try await makeFixture(
            kind: .sessionRefreshToken,
            refreshPlatform: "android"
        )
        var request = URLRequest(
            url: URL(string: "https://gateway.example.test/v1/responses")!
        )
        request.httpMethod = "POST"

        do {
            try await fixture.client.authorize(&request, feature: "habit-assistant")
            XCTFail("A refresh response for a different component platform must fail closed")
        } catch let error as LatchwayError {
            XCTAssertEqual(error, .invalidServerResponse)
        }

        let stored = await fixture.storage.load()
        XCTAssertEqual(stored?.rotationToken, String(repeating: "s", count: 64))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "DPoP"))
    }

    func testExtensionRuntimeCannotConsumeAnotherPlatformCredential() async throws {
        let cases: [(runtime: LatchwayClientRuntime, storedPlatform: String)] = [
            (.iOS, "react_native_ios"),
            (.reactNativeIOS, "ios"),
        ]

        for testCase in cases {
            let fixture = try await makeFixture(
                kind: .sessionRefreshToken,
                storedPlatform: testCase.storedPlatform,
                refreshPlatform: testCase.storedPlatform,
                clientRuntime: testCase.runtime
            )
            var request = URLRequest(
                url: URL(string: "https://gateway.example.test/v1/responses")!
            )
            request.httpMethod = "POST"

            do {
                try await fixture.client.authorize(&request, feature: "habit-assistant")
                XCTFail("A component credential from another runtime must fail closed")
            } catch let error as LatchwayComponentError {
                XCTAssertEqual(error, .componentKeyUnavailable)
            }

            let requestCount = await fixture.server.requestCount()
            XCTAssertEqual(requestCount, 0)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "DPoP"))
        }
    }

    func testReactNativeIOSExtensionAcceptsOnlyMatchingRuntimePlatform() async throws {
        let fixture = try await makeFixture(
            kind: .sessionRefreshToken,
            storedPlatform: "react_native_ios",
            refreshPlatform: "react_native_ios",
            clientRuntime: .reactNativeIOS
        )
        var request = URLRequest(
            url: URL(string: "https://gateway.example.test/v1/responses")!
        )
        request.httpMethod = "POST"

        try await fixture.client.authorize(&request, feature: "habit-assistant")

        let stored = await fixture.storage.load()
        let refreshCount = await fixture.server.requestCount(
            path: "/client/v1/sessions/refresh"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Latchway-SDK"), "react-native")
        XCTAssertEqual(stored?.component.platform, "react_native_ios")
        XCTAssertEqual(refreshCount, 1)
    }

    func testRefreshGrantCannotCrossIOSAndReactNativeIOSPlatforms() async throws {
        let cases: [(
            runtime: LatchwayClientRuntime,
            storedPlatform: String,
            responsePlatform: String
        )] = [
            (.iOS, "ios", "react_native_ios"),
            (.reactNativeIOS, "react_native_ios", "ios"),
        ]

        for testCase in cases {
            let fixture = try await makeFixture(
                kind: .sessionRefreshToken,
                storedPlatform: testCase.storedPlatform,
                refreshPlatform: testCase.responsePlatform,
                clientRuntime: testCase.runtime
            )
            var request = URLRequest(
                url: URL(string: "https://gateway.example.test/v1/responses")!
            )
            request.httpMethod = "POST"

            do {
                try await fixture.client.authorize(&request, feature: "habit-assistant")
                XCTFail("A refresh grant for another runtime must fail closed")
            } catch let error as LatchwayError {
                XCTAssertEqual(error, .invalidServerResponse)
            }

            let stored = await fixture.storage.load()
            let refreshCount = await fixture.server.requestCount(
                path: "/client/v1/sessions/refresh"
            )
            XCTAssertEqual(stored?.component.platform, testCase.storedPlatform)
            XCTAssertEqual(stored?.rotationToken, String(repeating: "s", count: 64))
            XCTAssertEqual(refreshCount, 1)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        }
    }

    func testRefreshReuseRetiresComponentCredential() async throws {
        let fixture = try await makeFixture(
            kind: .sessionRefreshToken,
            refreshRejection: "refresh_token_reused"
        )
        var request = URLRequest(
            url: URL(string: "https://gateway.example.test/v1/responses")!
        )
        request.httpMethod = "POST"

        do {
            try await fixture.client.authorize(&request, feature: "habit-assistant")
            XCTFail("A reused refresh token must retire the component locally")
        } catch let error as LatchwayComponentError {
            XCTAssertEqual(error, .componentRevoked)
        }

        let stored = await fixture.storage.load()
        XCTAssertNil(stored)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testConsumedProvisioningGrantIsClearedWhenRotatedValueCannotPersist() async throws {
        let fixture = try await makeFixture(
            kind: .provisioningGrant,
            failingSaveCalls: [1]
        )
        var request = URLRequest(
            url: URL(string: "https://gateway.example.test/v1/responses")!
        )
        request.httpMethod = "POST"
        await XCTAssertComponentThrowsError {
            try await fixture.client.authorize(&request, feature: "habit-assistant")
        }
        let stored = await fixture.storage.load()
        let clearCount = await fixture.storage.clearCount
        XCTAssertNil(stored)
        XCTAssertEqual(clearCount, 1)

        let diagnostics = await fixture.client.diagnostics()
        XCTAssertTrue(diagnostics.containingAppActionRequired)
        XCTAssertFalse(diagnostics.grantAvailable)
    }

    func testExtensionRejectsForeignDestinationsAndProviderCredentialsBeforeSessionUse() async throws {
        let fixture = try await makeFixture(kind: .provisioningGrant)
        var foreign = URLRequest(url: URL(string: "https://attacker.example/v1/responses")!)
        await XCTAssertComponentThrowsError {
            try await fixture.client.authorize(&foreign, feature: "habit-assistant")
        }
        var credential = URLRequest(
            url: URL(string: "https://gateway.example.test/v1/responses?api%255fkey=secret")!
        )
        await XCTAssertComponentThrowsError {
            try await fixture.client.authorize(&credential, feature: "habit-assistant")
        }
        var controlPath = URLRequest(
            url: URL(string: "https://gateway.example.test/client/v1/diagnostics")!
        )
        await XCTAssertComponentThrowsError {
            try await fixture.client.authorize(&controlPath, feature: "habit-assistant")
        }
        var encodedTraversal = URLRequest(
            url: URL(
                string: "https://gateway.example.test/v1/allowed%252F..%252Fclient/v1/diagnostics"
            )!
        )
        await XCTAssertComponentThrowsError {
            try await fixture.client.authorize(&encodedTraversal, feature: "habit-assistant")
        }
        var spoofedFramework = URLRequest(
            url: URL(string: "https://gateway.example.test/v1/responses")!
        )
        spoofedFramework.setValue("swift-openai", forHTTPHeaderField: "X-Latchway-Framework")
        spoofedFramework.setValue("4.6.0", forHTTPHeaderField: "X-Latchway-Framework-Version")
        await XCTAssertComponentThrowsError {
            try await fixture.client.authorize(&spoofedFramework, feature: "habit-assistant")
        }
        let requestCount = await fixture.server.requestCount()
        XCTAssertEqual(requestCount, 0)
        XCTAssertNil(foreign.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(credential.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(controlPath.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(encodedTraversal.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(spoofedFramework.value(forHTTPHeaderField: "Authorization"))
    }

    func testExtensionRejectsInsecureNonLoopbackGatewayBeforeSessionUse() async throws {
        let fixture = try await makeFixture(
            kind: .provisioningGrant,
            baseURL: URL(string: "http://gateway.example.test")!
        )
        var request = URLRequest(
            url: URL(string: "http://gateway.example.test/v1/responses")!
        )

        await XCTAssertComponentThrowsError {
            try await fixture.client.authorize(&request, feature: "habit-assistant")
        }

        let requestCount = await fixture.server.requestCount()
        XCTAssertEqual(requestCount, 0)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "DPoP"))
    }

    func testPublicDirectComponentAttestationFailsBeforeSessionUseForV1Runtimes() async throws {
        for (runtime, platform) in [
            (LatchwayClientRuntime.iOS, "ios"),
            (.reactNativeIOS, "react_native_ios"),
        ] {
            let fixture = try await makeDirectAttestationFixture(
                clientRuntime: runtime,
                componentPlatform: platform
            )

            await XCTAssertComponentThrowsError {
                try await fixture.client.establishDirectAttestation()
            }

            let requests = await fixture.server.requests
            let challenges = await fixture.provider.challenges
            let stored = await fixture.storage.load()
            XCTAssertEqual(requests.count, 0)
            XCTAssertEqual(challenges.count, 0)
            XCTAssertEqual(stored?.trustSource, .delegatedFromAttestedRoot)
        }
    }

    func testConcurrentDirectComponentAttestationUsesOneChallengeAndPersistsCompositeTrust() async throws {
        let fixture = try await makeDirectAttestationFixture()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 12 {
                group.addTask {
                    try await fixture.client.establishDirectAttestationForContractConformance()
                }
            }
            try await group.waitForAll()
        }
        try await fixture.client.establishDirectAttestationForContractConformance()

        let challengePath = "/client/v1/installation-families/current/components/"
            + "cmp_01J00000000000000000000000/attestation-challenges"
        let exchangePath = "/client/v1/installation-families/current/components/"
            + "cmp_01J00000000000000000000000/attestation-exchanges"
        let requests = await fixture.server.requests
        XCTAssertEqual(requests.filter { $0.url?.path == challengePath }.count, 1)
        XCTAssertEqual(requests.filter { $0.url?.path == exchangePath }.count, 1)
        for request in requests where [challengePath, exchangePath].contains(request.url?.path) {
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("DPoP ") == true)
            XCTAssertNotNil(request.value(forHTTPHeaderField: "DPoP"))
            XCTAssertEqual(request.httpMethod, "POST")
        }

        let exchange = try XCTUnwrap(requests.first { $0.url?.path == exchangePath })
        let exchangeObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(exchange.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(exchangeObject["challenge_id"] as? String, "chl_01J00000000000000000000003")
        let evidence = try XCTUnwrap(exchangeObject["attestation"] as? [String: Any])
        XCTAssertEqual(evidence["provider"] as? String, "app_attest")

        let challenges = await fixture.provider.challenges
        let accepted = await fixture.provider.acceptedEvidence
        XCTAssertEqual(challenges.count, 1)
        XCTAssertEqual(challenges[0].provider, "app_attest")
        XCTAssertEqual(challenges[0].clientDataHash, Data(repeating: 7, count: 32))
        XCTAssertEqual(challenges[0].options["bundle_id"], .string("com.example.action"))
        XCTAssertEqual(accepted.count, 1)

        let stored = await fixture.storage.load()
        XCTAssertEqual(stored?.trustSource, .delegatedDirectAttested)
        XCTAssertEqual(stored?.rotationToken, String(repeating: "d", count: 64))
        let diagnostics = await fixture.client.diagnostics()
        XCTAssertEqual(diagnostics.trustSource, .delegatedDirectAttested)
        XCTAssertTrue(diagnostics.sessionAvailable)
        XCTAssertFalse(diagnostics.containingAppActionRequired)
    }

    func testReactNativeIOSDirectAttestationRetainsExactComponentPlatform() async throws {
        let fixture = try await makeDirectAttestationFixture(
            clientRuntime: .reactNativeIOS,
            componentPlatform: "react_native_ios"
        )

        try await fixture.client.establishDirectAttestationForContractConformance()

        let stored = await fixture.storage.load()
        let requests = await fixture.server.requests
        XCTAssertEqual(stored?.component.platform, "react_native_ios")
        XCTAssertEqual(stored?.trustSource, .delegatedDirectAttested)
        XCTAssertTrue(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "X-Latchway-SDK") == "react-native"
        })
    }

    private struct DirectAttestationFixture {
        let client: LatchwayExtensionClient
        let storage: ComponentMemoryStorage
        let server: DirectComponentAttestationServer
        let provider: DirectComponentAttestationProvider
    }

    private func makeDirectAttestationFixture(
        clientRuntime: LatchwayClientRuntime = .iOS,
        componentPlatform: String = "ios"
    ) async throws -> DirectAttestationFixture {
        let raw = try decodeBase64URL("2ZFd1bc5bCB8zu8OEf5l7O9x_SxbsQNQMNn0si4NxxI")
        let key = try LatchwayDeterministicInstallationKey(rawPrivateKey: raw)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = LatchwayTestClock(now: now)
        let thumbprint = try await LatchwayDPoPProofFactory(key: key, clock: clock).thumbprint()
        let component = LatchwayComponentConfiguration(
            definitionID: "action_extension",
            kind: "action_extension",
            keychainAccessGroup: "TEAM123456.com.example.latchway.action",
            requestedFeatures: ["habit-assistant"]
        )
        let stored = LatchwayStoredComponentCredential(
            family: .init(id: "fam_01J00000000000000000000000", status: "active"),
            component: .init(
                id: "cmp_01J00000000000000000000000",
                definitionID: component.definitionID,
                kind: component.kind,
                platform: componentPlatform,
                isRoot: false,
                dpopJKT: thumbprint,
                status: "active",
                grantedFeatures: component.requestedFeatures
            ),
            requestedFeatures: component.requestedFeatures,
            trustSource: .delegatedFromAttestedRoot,
            trustExpiresAt: now.addingTimeInterval(7_200),
            keyThumbprint: thumbprint,
            rotationToken: String(repeating: "s", count: 64),
            rotationExpiresAt: now.addingTimeInterval(7_200),
            kind: .sessionRefreshToken
        )
        let storage = ComponentMemoryStorage(credential: stored)
        let server = DirectComponentAttestationServer(
            thumbprint: thumbprint,
            now: now,
            componentPlatform: componentPlatform
        )
        let provider = DirectComponentAttestationProvider()
        let configuration = LatchwayConfiguration(
            baseURL: URL(string: "https://gateway.example.test")!,
            applicationID: "app_01J00000000000000000000000",
            environment: "production",
            rootKeychainAccessGroup: "ABCDE12345.com.example.latchway",
            clientRuntime: clientRuntime,
            appVersion: "1.2.3"
        )
        return DirectAttestationFixture(
            client: try LatchwayExtensionClient(
                configuration: configuration,
                component: component,
                key: key,
                storage: storage,
                transport: server,
                clock: clock,
                directAttestationProvider: provider
            ),
            storage: storage,
            server: server,
            provider: provider
        )
    }

    private struct Fixture {
        let client: LatchwayExtensionClient
        let storage: ComponentMemoryStorage
        let server: ComponentServerTransport
    }

    private struct SharedComponentFixture {
        let clients: [LatchwayExtensionClient]
        let storage: ComponentMemoryStorage
        let server: ComponentServerTransport
    }

    private func makeSharedComponentFixture(
        kind: LatchwayComponentCredentialKind
    ) async throws -> SharedComponentFixture {
        let raw = try decodeBase64URL("2ZFd1bc5bCB8zu8OEf5l7O9x_SxbsQNQMNn0si4NxxI")
        let key = try LatchwayDeterministicInstallationKey(rawPrivateKey: raw)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = LatchwayTestClock(now: now)
        let thumbprint = try await LatchwayDPoPProofFactory(key: key, clock: clock).thumbprint()
        let component = LatchwayComponentConfiguration.widget(
            definitionID: "home_widget",
            keychainAccessGroup: "TEAM123456.com.example.latchway.widget",
            requestedFeatures: ["habit-assistant"]
        )
        let stored = LatchwayStoredComponentCredential(
            family: .init(id: "fam_01J00000000000000000000000", status: "active"),
            component: .init(
                id: "cmp_01J00000000000000000000000",
                definitionID: component.definitionID,
                kind: component.kind,
                platform: "ios",
                isRoot: false,
                dpopJKT: thumbprint,
                status: "active",
                grantedFeatures: component.requestedFeatures
            ),
            requestedFeatures: component.requestedFeatures,
            trustSource: .delegatedFromAttestedRoot,
            trustExpiresAt: now.addingTimeInterval(7_200),
            keyThumbprint: thumbprint,
            rotationToken: String(repeating: kind == .provisioningGrant ? "p" : "s", count: 64),
            rotationExpiresAt: now.addingTimeInterval(7_200),
            kind: kind
        )
        let storage = ComponentMemoryStorage(credential: stored)
        let server = ComponentServerTransport(
            thumbprint: thumbprint,
            refreshExpiresAt: now.addingTimeInterval(3_600),
            refreshPlatform: "ios",
            refreshRejection: nil,
            delay: .milliseconds(10)
        )
        let configuration = LatchwayConfiguration(
            baseURL: URL(string: "https://gateway.example.test")!,
            applicationID: "app_01J00000000000000000000000",
            environment: "production",
            rootKeychainAccessGroup: "ABCDE12345.com.example.latchway",
            appVersion: "1.2.3"
        )
        let namespace = "shared-component-\(UUID().uuidString)"
        let clients = try (0 ..< 2).map { _ in
            try LatchwayExtensionClient(
                configuration: configuration,
                component: component,
                key: key,
                storage: storage,
                transport: server,
                clock: clock,
                processScopeNamespace: namespace
            )
        }
        return SharedComponentFixture(clients: clients, storage: storage, server: server)
    }

    private struct SharedDirectAttestationFixture {
        let clients: [LatchwayExtensionClient]
        let storage: ComponentMemoryStorage
        let server: DirectComponentAttestationServer
        let providers: [DirectComponentAttestationProvider]
    }

    private func makeSharedDirectAttestationFixture() async throws
        -> SharedDirectAttestationFixture
    {
        let raw = try decodeBase64URL("2ZFd1bc5bCB8zu8OEf5l7O9x_SxbsQNQMNn0si4NxxI")
        let key = try LatchwayDeterministicInstallationKey(rawPrivateKey: raw)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = LatchwayTestClock(now: now)
        let thumbprint = try await LatchwayDPoPProofFactory(key: key, clock: clock).thumbprint()
        let component = LatchwayComponentConfiguration(
            definitionID: "action_extension",
            kind: "action_extension",
            keychainAccessGroup: "TEAM123456.com.example.latchway.action",
            requestedFeatures: ["habit-assistant"]
        )
        let stored = LatchwayStoredComponentCredential(
            family: .init(id: "fam_01J00000000000000000000000", status: "active"),
            component: .init(
                id: "cmp_01J00000000000000000000000",
                definitionID: component.definitionID,
                kind: component.kind,
                platform: "ios",
                isRoot: false,
                dpopJKT: thumbprint,
                status: "active",
                grantedFeatures: component.requestedFeatures
            ),
            requestedFeatures: component.requestedFeatures,
            trustSource: .delegatedFromAttestedRoot,
            trustExpiresAt: now.addingTimeInterval(7_200),
            keyThumbprint: thumbprint,
            rotationToken: String(repeating: "s", count: 64),
            rotationExpiresAt: now.addingTimeInterval(7_200),
            kind: .sessionRefreshToken
        )
        let storage = ComponentMemoryStorage(credential: stored)
        let server = DirectComponentAttestationServer(
            thumbprint: thumbprint,
            now: now,
            componentPlatform: "ios"
        )
        let providers = [DirectComponentAttestationProvider(), DirectComponentAttestationProvider()]
        let configuration = LatchwayConfiguration(
            baseURL: URL(string: "https://gateway.example.test")!,
            applicationID: "app_01J00000000000000000000000",
            environment: "production",
            rootKeychainAccessGroup: "ABCDE12345.com.example.latchway",
            appVersion: "1.2.3"
        )
        let namespace = "shared-direct-\(UUID().uuidString)"
        let clients = try providers.map { provider in
            try LatchwayExtensionClient(
                configuration: configuration,
                component: component,
                key: key,
                storage: storage,
                transport: server,
                clock: clock,
                directAttestationProvider: provider,
                processScopeNamespace: namespace
            )
        }
        return SharedDirectAttestationFixture(
            clients: clients,
            storage: storage,
            server: server,
            providers: providers
        )
    }

    private func makeFixture(
        kind: LatchwayComponentCredentialKind,
        failingSaveCalls: Set<Int> = [],
        serverDelay: Duration? = nil,
        storedPlatform: String = "ios",
        refreshPlatform: String = "ios",
        refreshRejection: String? = nil,
        baseURL: URL = URL(string: "https://gateway.example.test")!,
        clientRuntime: LatchwayClientRuntime = .iOS
    ) async throws -> Fixture {
        let raw = try decodeBase64URL("2ZFd1bc5bCB8zu8OEf5l7O9x_SxbsQNQMNn0si4NxxI")
        let key = try LatchwayDeterministicInstallationKey(rawPrivateKey: raw)
        let clock = LatchwayTestClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let thumbprint = try await LatchwayDPoPProofFactory(key: key, clock: clock).thumbprint()
        let component = LatchwayComponentConfiguration.widget(
            definitionID: "home_widget",
            keychainAccessGroup: "TEAM123456.com.example.latchway.widget",
            requestedFeatures: ["habit-assistant"]
        )
        let stored = LatchwayStoredComponentCredential(
            family: .init(id: "fam_01J00000000000000000000000", status: "active"),
            component: .init(
                id: "cmp_01J00000000000000000000000",
                definitionID: component.definitionID,
                kind: component.kind,
                platform: storedPlatform,
                isRoot: false,
                dpopJKT: thumbprint,
                status: "active",
                grantedFeatures: component.requestedFeatures
            ),
            requestedFeatures: component.requestedFeatures,
            trustSource: .delegatedFromAttestedRoot,
            trustExpiresAt: Date(timeIntervalSince1970: 1_700_007_200),
            keyThumbprint: thumbprint,
            rotationToken: String(repeating: kind == .provisioningGrant ? "p" : "s", count: 64),
            rotationExpiresAt: Date(timeIntervalSince1970: 1_700_007_200),
            kind: kind
        )
        let storage = ComponentMemoryStorage(
            credential: stored,
            failingSaveCalls: failingSaveCalls
        )
        let server = ComponentServerTransport(
            thumbprint: thumbprint,
            refreshExpiresAt: Date(timeIntervalSince1970: 1_700_003_600),
            refreshPlatform: refreshPlatform,
            refreshRejection: refreshRejection,
            delay: serverDelay
        )
        let configuration = LatchwayConfiguration(
            baseURL: baseURL,
            applicationID: "app_01J00000000000000000000000",
            environment: "production",
            rootKeychainAccessGroup: "ABCDE12345.com.example.latchway",
            clientRuntime: clientRuntime,
            appVersion: "1.2.3"
        )
        return Fixture(
            client: try LatchwayExtensionClient(
                configuration: configuration,
                component: component,
                key: key,
                storage: storage,
                transport: server,
                clock: clock
            ),
            storage: storage,
            server: server
        )
    }
}

private actor DirectComponentAttestationProvider: LatchwayAttestationProvider {
    private(set) var challenges: [LatchwayAttestationChallenge] = []
    private(set) var acceptedEvidence: [LatchwayAttestationEvidence] = []

    func evidence(
        for challenge: LatchwayAttestationChallenge
    ) -> LatchwayAttestationEvidence {
        challenges.append(challenge)
        return LatchwayAttestationEvidence(provider: "app_attest", evidence: [
            "key_id": .string("component-app-attest-key"),
            "attestation_object": .string("Y29tcG9uZW50LWF0dGVzdGF0aW9u"),
            "client_data_hash": .string(Base64URL.encode(challenge.clientDataHash)),
        ])
    }

    func didAccept(_ evidence: LatchwayAttestationEvidence) {
        acceptedEvidence.append(evidence)
    }

    func reset() {
        challenges = []
        acceptedEvidence = []
    }

    func status() -> LatchwayAttestationStatus {
        .init(support: .supported, keyID: "component-app-attest-key")
    }
}

private actor DirectComponentAttestationServer: LatchwayHTTPTransport {
    private let thumbprint: String
    private let now: Date
    private let componentPlatform: String
    private(set) var requests: [URLRequest] = []

    init(thumbprint: String, now: Date, componentPlatform: String) {
        self.thumbprint = thumbprint
        self.now = now
        self.componentPlatform = componentPlatform
    }

    func send(_ request: URLRequest) throws -> LatchwayHTTPResponse {
        requests.append(request)
        let componentBase = "/client/v1/installation-families/current/components/"
            + "cmp_01J00000000000000000000000"
        switch request.url?.path {
        case "/client/v1/sessions/refresh":
            return try grant(
                statusCode: 200,
                accessTokenByte: "a",
                refreshTokenByte: "r",
                trustSource: "delegated_from_attested_root"
            )
        case componentBase + "/attestation-challenges":
            return try jsonResponse(statusCode: 201, object: [
                "challenge_id": "chl_01J00000000000000000000003",
                "challenge_nonce": Base64URL.encode(Data(repeating: 0x22, count: 32)),
                "binding_version": 2,
                "issued_at": Int64(now.timeIntervalSince1970),
                "expires_at": dateString(now.addingTimeInterval(300)),
                "attestation": [
                    "provider": "app_attest",
                    "mode": "required",
                    "client_data_hash": Base64URL.encode(Data(repeating: 7, count: 32)),
                    "provider_options": [
                        "app_id_prefix": "TEAM123456",
                        "bundle_id": "com.example.action",
                    ],
                ],
            ])
        case componentBase + "/attestation-exchanges":
            return try grant(
                statusCode: 201,
                accessTokenByte: "b",
                refreshTokenByte: "d",
                trustSource: "delegated_direct_attested"
            )
        default:
            return try jsonResponse(statusCode: 500, object: [:])
        }
    }

    func requestCount(path: String) -> Int {
        requests.filter { $0.url?.path == path }.count
    }

    private func grant(
        statusCode: Int,
        accessTokenByte: String,
        refreshTokenByte: String,
        trustSource: String
    ) throws -> LatchwayHTTPResponse {
        try jsonResponse(statusCode: statusCode, object: [
            "access_token": String(repeating: accessTokenByte, count: 96),
            "token_type": "DPoP",
            "expires_in": 900,
            "refresh_token": String(repeating: refreshTokenByte, count: 64),
            "refresh_expires_in": 3_600,
            "installation": [
                "id": "ins_01J00000000000000000000000",
                "platform": componentPlatform,
                "dpop_jkt": thumbprint,
                "status": "active",
            ],
            "installation_family": [
                "id": "fam_01J00000000000000000000000",
                "status": "active",
            ],
            "component": [
                "id": "cmp_01J00000000000000000000000",
                "definition_id": "action_extension",
                "kind": "action_extension",
                "platform": componentPlatform,
                "is_root": false,
                "dpop_jkt": thumbprint,
                "status": "active",
                "granted_features": ["habit-assistant"],
            ],
            "trust": [
                "provider": "app_attest",
                "level": "app_verified",
                "source": trustSource,
                "parent_component_id": "cmp_01J00000000000000000000001",
                "parent_attestation_provider": "app_attest",
                "delegation_id": "dlg_01J00000000000000000000000",
                "verified_at": dateString(now),
                "expires_at": dateString(now.addingTimeInterval(7_200)),
            ],
        ])
    }

    private func jsonResponse(
        statusCode: Int,
        object: [String: Any]
    ) throws -> LatchwayHTTPResponse {
        LatchwayHTTPResponse(
            statusCode: statusCode,
            headers: ["Content-Type": "application/json"],
            body: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )
    }

    private func dateString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

private actor ComponentMemoryStorage: LatchwayComponentCredentialStorage {
    private var credential: LatchwayStoredComponentCredential?
    private let failingSaveCalls: Set<Int>
    private(set) var saveCount = 0
    private(set) var clearCount = 0

    init(
        credential: LatchwayStoredComponentCredential?,
        failingSaveCalls: Set<Int> = []
    ) {
        self.credential = credential
        self.failingSaveCalls = failingSaveCalls
    }

    func load() -> LatchwayStoredComponentCredential? { credential }

    func save(_ credential: LatchwayStoredComponentCredential) throws {
        saveCount += 1
        guard !failingSaveCalls.contains(saveCount) else {
            throw LatchwayError.keyStorageFailure
        }
        self.credential = credential
    }

    func clear() {
        credential = nil
        clearCount += 1
    }
}

private actor ComponentServerTransport: LatchwayHTTPTransport {
    private let thumbprint: String
    private(set) var requests: [URLRequest] = []
    private let refreshExpiresAt: Date
    private let refreshPlatform: String
    private let refreshRejection: String?
    private let delay: Duration?

    init(
        thumbprint: String,
        refreshExpiresAt: Date,
        refreshPlatform: String,
        refreshRejection: String?,
        delay: Duration?
    ) {
        self.thumbprint = thumbprint
        self.refreshExpiresAt = refreshExpiresAt
        self.refreshPlatform = refreshPlatform
        self.refreshRejection = refreshRejection
        self.delay = delay
    }

    func send(_ request: URLRequest) async throws -> LatchwayHTTPResponse {
        requests.append(request)
        if let delay { try await Task.sleep(for: delay) }
        switch request.url?.path {
        case "/client/v1/component-sessions", "/client/v1/sessions/refresh":
            if request.url?.path == "/client/v1/sessions/refresh",
               let refreshRejection {
                let requestID = request.value(
                    forHTTPHeaderField: "X-Latchway-Request-ID"
                ) ?? "request-12345678"
                return LatchwayHTTPResponse(
                    statusCode: 401,
                    headers: [
                        "Content-Type": "application/problem+json",
                        "X-Latchway-Request-ID": requestID,
                    ],
                    body: try JSONSerialization.data(withJSONObject: [
                        "type": "https://docs.latchway.dev/errors/\(refreshRejection.replacingOccurrences(of: "_", with: "-"))",
                        "documentation_url": "https://docs.latchway.dev/errors/\(refreshRejection.replacingOccurrences(of: "_", with: "-"))",
                        "title": "Refresh rejected",
                        "status": 401,
                        "detail": "The component refresh chain is no longer active.",
                        "code": refreshRejection,
                        "request_id": requestID,
                        "retryable": false,
                    ], options: [.sortedKeys])
                )
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            var body: [String: Any] = [
                "access_token": String(repeating: "a", count: 96),
                "expires_in": 900,
                "refresh_token": String(repeating: "r", count: 64),
            ]
            if request.url?.path == "/client/v1/component-sessions" {
                body["refresh_expires_at"] = formatter.string(from: refreshExpiresAt)
            } else {
                body["token_type"] = "DPoP"
                body["refresh_expires_in"] = 3_600
                body["installation"] = [
                    "id": "ins_01J00000000000000000000000",
                    "platform": refreshPlatform,
                    "dpop_jkt": thumbprint,
                    "status": "active",
                ]
                body["installation_family"] = [
                    "id": "fam_01J00000000000000000000000",
                    "status": "active",
                ]
                body["component"] = [
                    "id": "cmp_01J00000000000000000000000",
                    "definition_id": "home_widget",
                    "kind": "widget",
                    "platform": refreshPlatform,
                    "is_root": false,
                    "dpop_jkt": thumbprint,
                    "status": "active",
                    "granted_features": ["habit-assistant"],
                ]
                body["trust"] = [
                    "provider": "app_attest",
                    "level": "app_verified",
                    "source": "delegated_from_attested_root",
                    "parent_component_id": "cmp_01J00000000000000000000001",
                    "parent_attestation_provider": "app_attest",
                    "delegation_id": "dlg_01J00000000000000000000000",
                    "verified_at": formatter.string(
                        from: Date(timeIntervalSince1970: 1_700_000_000)
                    ),
                    "expires_at": formatter.string(from: refreshExpiresAt),
                ]
            }
            return LatchwayHTTPResponse(
                statusCode: request.url?.path == "/client/v1/component-sessions" ? 201 : 200,
                headers: ["Content-Type": "application/json"],
                body: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            )
        default:
            return LatchwayHTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data("{}".utf8)
            )
        }
    }

    func requestCount(path: String? = nil) -> Int {
        guard let path else { return requests.count }
        return requests.filter { $0.url?.path == path }.count
    }

    func requests(path: String) -> [URLRequest] {
        requests.filter { $0.url?.path == path }
    }
}

private func decodeBase64URL(_ value: String) throws -> Data {
    var base64 = value.replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
    return try XCTUnwrap(Data(base64Encoded: base64))
}

private func proofHeader(_ proof: String) throws -> [String: Any] {
    try proofPart(proof, index: 0)
}

private func proofPayload(_ proof: String) throws -> [String: Any] {
    try proofPart(proof, index: 1)
}

private func proofPart(_ proof: String, index: Int) throws -> [String: Any] {
    let segments = proof.split(separator: ".")
    XCTAssertEqual(segments.count, 3)
    let data = try decodeBase64URL(String(segments[index]))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func XCTAssertComponentThrowsError(
    _ operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("Expected an error", file: file, line: line)
    } catch {}
}
