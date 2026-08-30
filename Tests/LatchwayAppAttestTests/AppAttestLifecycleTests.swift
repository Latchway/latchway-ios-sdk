import Foundation
import Latchway
@testable import LatchwayAppAttest
import Security
import XCTest

final class AppAttestLifecycleTests: XCTestCase {
    func testPublicRootInitializersAcceptConcreteAndLegacyGroups() {
        let root = "ABCDE12345.com.example.latchway"
        let legacy = ["ABCDE12345.com.example.latchway.appintents"]
        _ = LatchwayAppAttestProvider(
            applicationID: "app_01J00000000000000000000000",
            environment: "production",
            rootKeychainAccessGroup: root,
            legacySharedKeychainAccessGroups: legacy
        )
        _ = LatchwayAppAttestProvider(
            rootKeychainAccessGroup: root,
            legacySharedKeychainAccessGroups: legacy,
            storageNamespace: "custom"
        )
    }

    func testEveryAppAttestKeychainIdentityCarriesExplicitAccessGroup() {
        let group = "ABCDE12345.com.example.latchway"
        let identity = AppAttestKeychainQuery.identity(
            service: "dev.latchway.sdk.app-attest.custom",
            account: "app-attest-state",
            accessGroup: group,
            synchronizable: kCFBooleanFalse as Any
        )
        XCTAssertEqual(identity[kSecAttrAccessGroup] as? String, group)
    }

    func testCustomNamespaceLegacySharedStateBlocksBeforeDeviceCheck() async {
        let service = FakeService()
        let legacy = MemoryStateStore(
            initial: .init(keyID: "legacy-key", acceptedByLatchway: true)
        )
        let provider = LatchwayAppAttestProvider(
            service: service,
            stateStore: MemoryStateStore(),
            legacyStateStores: [legacy],
            rootKeychainAccessGroup: "ABCDE12345.com.example.latchway",
            legacySharedKeychainAccessGroups: [
                "ABCDE12345.com.example.latchway.appintents",
            ],
            rootKeychainPreflight: {}
        )

        do {
            _ = try await provider.evidence(for: fixtureChallenge())
            XCTFail("Expected legacy shared App Attest state to block")
        } catch let error as LatchwayError {
            XCTAssertEqual(error, .rootKeychainMigrationRequired)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let counts = await service.counts()
        XCTAssertEqual(counts.generateKey, 0)
        XCTAssertEqual(counts.attestation, 0)
        XCTAssertEqual(counts.assertion, 0)
    }

    func testSentinelMismatchWithoutLegacyStateIsInvalidBeforeDeviceCheck() async {
        let service = FakeService()
        let provider = LatchwayAppAttestProvider(
            service: service,
            stateStore: MemoryStateStore(),
            legacyStateStores: [],
            rootKeychainAccessGroup: "ABCDE12345.com.example.latchway",
            legacySharedKeychainAccessGroups: [],
            rootKeychainPreflight: {
                throw LatchwayError.invalidConfiguration("not the signed default group")
            }
        )

        do {
            _ = try await provider.evidence(for: fixtureChallenge())
            XCTFail("Expected signed-default mismatch")
        } catch let error as LatchwayError {
            guard case .invalidConfiguration = error else {
                return XCTFail("Expected invalid configuration, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let counts = await service.counts()
        XCTAssertEqual(counts.generateKey, 0)
        XCTAssertEqual(counts.attestation, 0)
        XCTAssertEqual(counts.assertion, 0)
    }

    func testAppAttestRootPreflightIsCached() async {
        let counter = AppAttestPreflightCounter()
        let provider = LatchwayAppAttestProvider(
            service: FakeService(),
            stateStore: MemoryStateStore(),
            legacyStateStores: [],
            rootKeychainAccessGroup: "ABCDE12345.com.example.latchway",
            legacySharedKeychainAccessGroups: [],
            rootKeychainPreflight: { counter.increment() }
        )

        _ = await provider.status()
        _ = await provider.status()
        XCTAssertEqual(counter.value, 1)
    }

    func testComponentStorageNamespacesDoNotReuseRootOrSiblingMarkers() {
        let first = LatchwayAppAttestProvider.componentStorageNamespace(
            applicationID: "app_01J00000000000000000000000",
            environment: "production",
            clientRuntime: .iOS,
            componentDefinitionID: "action_extension"
        )
        let sibling = LatchwayAppAttestProvider.componentStorageNamespace(
            applicationID: "app_01J00000000000000000000000",
            environment: "production",
            clientRuntime: .iOS,
            componentDefinitionID: "sso_extension"
        )

        XCTAssertEqual(
            first,
            "ios.app_01J00000000000000000000000.production.component.action_extension"
        )
        XCTAssertNotEqual(first, sibling)
        XCTAssertNotEqual(
            first,
            "ios.app_01J00000000000000000000000.production"
        )
    }

    func testRegistrationThenAssertion() async throws {
        let service = FakeService()
        let store = MemoryStateStore()
        let provider = LatchwayAppAttestProvider(service: service, stateStore: store)
        let challenge = fixtureChallenge()

        let registration = try await provider.evidence(for: challenge)
        XCTAssertNotNil(registration.evidence["attestation_object"])
        XCTAssertNil(registration.evidence["assertion_object"])
        await provider.didAccept(registration)

        let assertion = try await provider.evidence(for: challenge)
        XCTAssertNil(assertion.evidence["attestation_object"])
        XCTAssertNotNil(assertion.evidence["assertion_object"])
        let counts = await service.counts()
        XCTAssertEqual(counts.generateKey, 1)
        XCTAssertEqual(counts.attestation, 1)
        XCTAssertEqual(counts.assertion, 1)
    }

    func testAcceptedStatePersistsAcrossProviderInstances() async throws {
        let service = FakeService()
        let store = MemoryStateStore()
        let firstProvider = LatchwayAppAttestProvider(service: service, stateStore: store)
        let registration = try await firstProvider.evidence(for: fixtureChallenge())
        await firstProvider.didAccept(registration)

        let reloadedProvider = LatchwayAppAttestProvider(service: service, stateStore: store)
        let assertion = try await reloadedProvider.evidence(for: fixtureChallenge())

        XCTAssertNil(assertion.evidence["attestation_object"])
        XCTAssertNotNil(assertion.evidence["assertion_object"])
        let counts = await service.counts()
        XCTAssertEqual(counts.generateKey, 1)
        XCTAssertEqual(counts.attestation, 1)
        XCTAssertEqual(counts.assertion, 1)
    }

    func testAcceptancePersistenceFailureKeepsLiveAndReloadedProvidersUnaccepted() async throws {
        let service = FakeService()
        let store = MemoryStateStore()
        let provider = LatchwayAppAttestProvider(service: service, stateStore: store)
        let registration = try await provider.evidence(for: fixtureChallenge())
        await store.failNextSave()

        await provider.didAccept(registration)
        let failedStatus = await provider.status()
        XCTAssertEqual(failedStatus.lastOperation, "state_persistence_failed")

        let sameProviderEvidence = try await provider.evidence(for: fixtureChallenge())
        let reloadedProvider = LatchwayAppAttestProvider(service: service, stateStore: store)
        let reloadedEvidence = try await reloadedProvider.evidence(for: fixtureChallenge())
        XCTAssertNotNil(sameProviderEvidence.evidence["attestation_object"])
        XCTAssertNil(sameProviderEvidence.evidence["assertion_object"])
        XCTAssertNotNil(reloadedEvidence.evidence["attestation_object"])
        XCTAssertNil(reloadedEvidence.evidence["assertion_object"])
        let counts = await service.counts()
        XCTAssertEqual(counts.attestation, 3)
        XCTAssertEqual(counts.assertion, 0)
    }

    func testResetWaitsForInFlightAcceptancePersistenceBeforeClearingState() async throws {
        let service = FakeService()
        let store = SuspendedSaveStateStore()
        let provider = LatchwayAppAttestProvider(service: service, stateStore: store)
        let registration = try await provider.evidence(for: fixtureChallenge())
        await store.suspendNextSave()

        let acceptance = Task { await provider.didAccept(registration) }
        await store.waitUntilSaveStarts()
        let reset = Task { try await provider.reset() }
        for _ in 0 ..< 10_000 {
            if await provider.status().lastOperation == "reset" { break }
            await Task.yield()
        }
        let clearCountWhileSaveIsSuspended = await store.clearCount()
        XCTAssertEqual(clearCountWhileSaveIsSuspended, 0)

        await store.finishSave()
        await acceptance.value
        try await reset.value

        let persisted = try await store.load()
        let finalClearCount = await store.clearCount()
        let finalStatus = await provider.status()
        XCTAssertNil(persisted)
        XCTAssertEqual(finalClearCount, 1)
        XCTAssertEqual(finalStatus.lastOperation, "reset")
    }

    func testInvalidKeyRecoveryIsBoundedToOneRotation() async throws {
        let service = FakeService(assertionFailures: [.invalidKey])
        let store = MemoryStateStore(initial: .init(keyID: "stale", acceptedByLatchway: true))
        let provider = LatchwayAppAttestProvider(service: service, stateStore: store)
        let evidence = try await provider.evidence(for: fixtureChallenge())
        XCTAssertNotNil(evidence.evidence["attestation_object"])
        let counts = await service.counts()
        let status = await provider.status()
        XCTAssertEqual(counts.generateKey, 1)
        XCTAssertEqual(status.lastOperation, "attestation")
    }

    func testConcurrentInvalidKeyObservationsShareOneRecoveryGeneration() async throws {
        let service = SuspendedInvalidAssertionService()
        let store = MemoryStateStore(initial: .init(keyID: "stale", acceptedByLatchway: true))
        let provider = LatchwayAppAttestProvider(service: service, stateStore: store)
        let firstChallenge = fixtureChallenge()
        let secondChallenge = LatchwayAttestationChallenge(
            id: "chl_01J00000000000000000000001",
            provider: "app_attest",
            clientDataHash: Data(repeating: 8, count: 32),
            expiresAt: Date().addingTimeInterval(300)
        )

        let firstTask = Task { try await provider.evidence(for: firstChallenge) }
        await service.waitUntilAssertionCount(1)
        let secondTask = Task { try await provider.evidence(for: secondChallenge) }
        await service.waitUntilAssertionCount(2)

        await service.releaseAssertion(1)
        await service.waitUntilAttestationCount(1)
        await service.releaseAssertion(2)
        let evidence = try await [firstTask, secondTask].asyncValues()

        XCTAssertEqual(Set(evidence.compactMap { item -> String? in
            guard case let .string(keyID)? = item.evidence["key_id"] else { return nil }
            return keyID
        }), ["generated-key-1"])
        let persisted = try await store.load()
        XCTAssertEqual(persisted, .init(keyID: "generated-key-1", acceptedByLatchway: false))
        let counts = await service.counts()
        XCTAssertEqual(counts.generateKey, 1)
        XCTAssertEqual(counts.attestation, 2)
        XCTAssertEqual(counts.assertion, 2)
    }

    func testSecondInvalidKeyFailsWithoutInfiniteRecovery() async {
        let service = FakeService(attestationFailures: [.invalidKey], assertionFailures: [.invalidKey])
        let store = MemoryStateStore(initial: .init(keyID: "stale", acceptedByLatchway: true))
        let provider = LatchwayAppAttestProvider(service: service, stateStore: store)
        do {
            _ = try await provider.evidence(for: fixtureChallenge())
            XCTFail("Expected bounded recovery to fail")
        } catch let error as LatchwayError {
            XCTAssertEqual(error, .attestationUnavailable)
            let counts = await service.counts()
            XCTAssertEqual(counts.generateKey, 1)
            XCTAssertEqual(counts.attestation, 1)
        } catch {
            XCTFail("Expected a stable LatchwayError, got \(type(of: error))")
        }
    }

    func testInvalidClientDataHashFailsClosed() async {
        let provider = LatchwayAppAttestProvider(service: FakeService(), stateStore: MemoryStateStore())
        let challenge = LatchwayAttestationChallenge(
            id: "chl_01J00000000000000000000000",
            provider: "app_attest",
            clientDataHash: Data(repeating: 0, count: 31),
            expiresAt: Date().addingTimeInterval(60)
        )
        await XCTAssertThrowsErrorAsync { _ = try await provider.evidence(for: challenge) }
    }

    func testExpiredAndWrongProviderChallengesFailBeforeServiceUse() async {
        for challenge in [
            LatchwayAttestationChallenge(
                id: "chl_01J00000000000000000000000",
                provider: "app_attest",
                clientDataHash: Data(repeating: 7, count: 32),
                expiresAt: Date().addingTimeInterval(-1)
            ),
            LatchwayAttestationChallenge(
                id: "chl_01J00000000000000000000000",
                provider: "play_integrity",
                clientDataHash: Data(repeating: 7, count: 32),
                expiresAt: Date().addingTimeInterval(60)
            ),
        ] {
            let service = FakeService()
            let provider = LatchwayAppAttestProvider(service: service, stateStore: MemoryStateStore())
            do {
                _ = try await provider.evidence(for: challenge)
                XCTFail("Expected the invalid challenge to fail")
            } catch let error as LatchwayError {
                let expected: LatchwayError = challenge.provider == "app_attest"
                    ? .invalidAttestationBinding : .attestationUnavailable
                XCTAssertEqual(error, expected)
            } catch {
                XCTFail("Expected a stable LatchwayError, got \(type(of: error))")
            }
            let counts = await service.counts()
            XCTAssertEqual(counts.generateKey, 0)
            XCTAssertEqual(counts.attestation, 0)
            XCTAssertEqual(counts.assertion, 0)
        }
    }

    func testAttestationAndAssertionOutputBoundsFailClosed() async {
        let oversized = Data(repeating: 1, count: 65_537)
        for fixture in [
            (
                FakeService(attestationResult: Data()),
                MemoryStateStore() as MemoryStateStore
            ),
            (
                FakeService(attestationResult: oversized),
                MemoryStateStore() as MemoryStateStore
            ),
            (
                FakeService(assertionResult: Data()),
                MemoryStateStore(initial: .init(keyID: "accepted", acceptedByLatchway: true))
            ),
            (
                FakeService(assertionResult: oversized),
                MemoryStateStore(initial: .init(keyID: "accepted", acceptedByLatchway: true))
            ),
        ] {
            let provider = LatchwayAppAttestProvider(service: fixture.0, stateStore: fixture.1)
            do {
                _ = try await provider.evidence(for: fixtureChallenge())
                XCTFail("Expected out-of-bounds evidence to fail")
            } catch let error as LatchwayError {
                XCTAssertEqual(error, .attestationUnavailable)
            } catch {
                XCTFail("Expected a stable LatchwayError, got \(type(of: error))")
            }
        }
    }

    func testCancellationUsesStableErrorWithoutServiceUse() async {
        let service = FakeService()
        let provider = LatchwayAppAttestProvider(service: service, stateStore: MemoryStateStore())
        let challenge = fixtureChallenge()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await provider.evidence(for: challenge)
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch let error as LatchwayError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("Expected a stable LatchwayError, got \(type(of: error))")
        }
        let counts = await service.counts()
        XCTAssertEqual(counts.generateKey, 0)
    }

    func testCancellationDuringKeyGenerationPersistsTheGeneratedKeyBeforeFailing() async throws {
        let service = SuspendedKeyService()
        let store = MemoryStateStore()
        let provider = LatchwayAppAttestProvider(service: service, stateStore: store)
        let challenge = fixtureChallenge()
        let task = Task { try await provider.evidence(for: challenge) }

        await service.waitUntilKeyGenerationStarts()
        task.cancel()
        await service.finishKeyGeneration()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch let error as LatchwayError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("Expected a stable LatchwayError, got \(type(of: error))")
        }

        let persisted = try await store.load()
        XCTAssertEqual(persisted, .init(keyID: "generated-key-1", acceptedByLatchway: false))

        let evidence = try await provider.evidence(for: challenge)
        XCTAssertNotNil(evidence.evidence["attestation_object"])
        let counts = await service.counts()
        XCTAssertEqual(counts.generateKey, 1)
        XCTAssertEqual(counts.attestation, 1)
    }

    func testCancellationDuringStateLoadDoesNotLaunchKeyGeneration() async throws {
        let service = FakeService()
        let store = SuspendedLoadStateStore()
        let provider = LatchwayAppAttestProvider(service: service, stateStore: store)
        let challenge = fixtureChallenge()
        let task = Task { try await provider.evidence(for: challenge) }

        await store.waitUntilLoadStarts()
        task.cancel()
        await store.finishLoad()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch let error as LatchwayError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("Expected a stable LatchwayError, got \(type(of: error))")
        }
        let counts = await service.counts()
        let persisted = try await store.load()
        XCTAssertEqual(counts.generateKey, 0)
        XCTAssertNil(persisted)
    }

    func testConcurrentFirstUseGeneratesAndPersistsOneSharedKey() async throws {
        let service = SuspendedKeyService()
        let store = MemoryStateStore()
        let provider = LatchwayAppAttestProvider(service: service, stateStore: store)
        let challenge = fixtureChallenge()
        let tasks = (0 ..< 16).map { _ in
            Task { try await provider.evidence(for: challenge) }
        }

        await service.waitUntilKeyGenerationStarts()
        await service.finishKeyGeneration()
        let evidence = try await tasks.asyncValues()

        XCTAssertEqual(Set(evidence.compactMap { item -> String? in
            guard case let .string(keyID)? = item.evidence["key_id"] else { return nil }
            return keyID
        }), ["generated-key-1"])
        let persisted = try await store.load()
        XCTAssertEqual(persisted, .init(keyID: "generated-key-1", acceptedByLatchway: false))
        let counts = await service.counts()
        XCTAssertEqual(counts.generateKey, 1)
        XCTAssertEqual(counts.attestation, 16)
    }

    func testResetDuringKeyGenerationPreventsPostResetStateResurrection() async throws {
        let service = SuspendedKeyService()
        let store = MemoryStateStore()
        let provider = LatchwayAppAttestProvider(service: service, stateStore: store)
        let challenge = fixtureChallenge()
        let evidenceTask = Task { try await provider.evidence(for: challenge) }

        await service.waitUntilKeyGenerationStarts()
        let resetTask = Task { try await provider.reset() }
        await service.waitUntilCancellationIsObserved()
        await service.finishKeyGeneration()
        try await resetTask.value

        do {
            _ = try await evidenceTask.value
            XCTFail("Expected the pre-reset evidence operation to be cancelled")
        } catch let error as LatchwayError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("Expected a stable LatchwayError, got \(type(of: error))")
        }
        let cleared = try await store.load()
        let resetStatus = await provider.status()
        XCTAssertNil(cleared)
        XCTAssertNil(resetStatus.keyID)

        let evidence = try await provider.evidence(for: challenge)
        guard case let .string(keyID)? = evidence.evidence["key_id"] else {
            return XCTFail("Expected a recovered key identifier")
        }
        XCTAssertEqual(keyID, "generated-key-2")
        let persisted = try await store.load()
        XCTAssertEqual(persisted, .init(keyID: "generated-key-2", acceptedByLatchway: false))
        let counts = await service.counts()
        XCTAssertEqual(counts.generateKey, 2)
    }

    func testStateStoreLoadSaveAndRecoveryClearFailuresFailClosed() async {
        let loadProvider = LatchwayAppAttestProvider(
            service: FakeService(),
            stateStore: MemoryStateStore(loadFailures: 1)
        )
        await assertStableError(.keyStorageFailure) {
            _ = try await loadProvider.evidence(for: self.fixtureChallenge())
        }

        let saveService = FakeService()
        let saveProvider = LatchwayAppAttestProvider(
            service: saveService,
            stateStore: MemoryStateStore(saveFailures: 1)
        )
        await assertStableError(.keyStorageFailure) {
            _ = try await saveProvider.evidence(for: self.fixtureChallenge())
        }
        let saveCounts = await saveService.counts()
        XCTAssertEqual(saveCounts.generateKey, 1)

        let clearService = FakeService(assertionFailures: [.invalidKey])
        let clearProvider = LatchwayAppAttestProvider(
            service: clearService,
            stateStore: MemoryStateStore(
                initial: .init(keyID: "stale", acceptedByLatchway: true),
                clearFailures: 1
            )
        )
        await assertStableError(.keyStorageFailure) {
            _ = try await clearProvider.evidence(for: self.fixtureChallenge())
        }
        let clearCounts = await clearService.counts()
        XCTAssertEqual(clearCounts.generateKey, 0)
    }

    func testResetClearFailureUsesStableStorageError() async {
        let provider = LatchwayAppAttestProvider(
            service: FakeService(),
            stateStore: MemoryStateStore(clearFailures: 1)
        )
        await assertStableError(.keyStorageFailure) { try await provider.reset() }
    }

    func testUnsupportedDeviceFailsClosedWithoutCreatingAKey() async {
        let service = FakeService(supported: false)
        let provider = LatchwayAppAttestProvider(service: service, stateStore: MemoryStateStore())

        do {
            _ = try await provider.evidence(for: fixtureChallenge())
            XCTFail("Expected App Attest to be unavailable")
        } catch let error as LatchwayError {
            XCTAssertEqual(error, .attestationUnavailable)
        } catch {
            XCTFail("Expected a stable LatchwayError, got \(type(of: error))")
        }

        let counts = await service.counts()
        XCTAssertEqual(counts.generateKey, 0)
        XCTAssertEqual(counts.attestation, 0)
        XCTAssertEqual(counts.assertion, 0)
    }

    func testKeyCreationFailureUsesStableRedactedError() async {
        let provider = LatchwayAppAttestProvider(
            service: FakeService(generateKeyFailures: [.serverUnavailable]),
            stateStore: MemoryStateStore()
        )
        do {
            _ = try await provider.evidence(for: fixtureChallenge())
            XCTFail("Expected App Attest key creation to fail")
        } catch let error as LatchwayError {
            XCTAssertEqual(error, .attestationUnavailable)
        } catch {
            XCTFail("Expected a stable LatchwayError, got \(type(of: error))")
        }
    }

    private func fixtureChallenge() -> LatchwayAttestationChallenge {
        LatchwayAttestationChallenge(
            id: "chl_01J00000000000000000000000",
            provider: "app_attest",
            clientDataHash: Data(repeating: 7, count: 32),
            expiresAt: Date().addingTimeInterval(300)
        )
    }

    private func assertStableError(
        _ expected: LatchwayError,
        operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as LatchwayError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Expected a stable LatchwayError, got \(type(of: error))", file: file, line: line)
        }
    }
}

private actor FakeService: AppAttestServicing {
    private let supported: Bool
    private var generateKeyFailures: [AppAttestOperationError]
    private var attestationFailures: [AppAttestOperationError]
    private var assertionFailures: [AppAttestOperationError]
    private let attestationResult: Data
    private let assertionResult: Data
    private(set) var generateKeyCount = 0
    private(set) var attestationCount = 0
    private(set) var assertionCount = 0

    init(
        supported: Bool = true,
        generateKeyFailures: [AppAttestOperationError] = [],
        attestationFailures: [AppAttestOperationError] = [],
        assertionFailures: [AppAttestOperationError] = [],
        attestationResult: Data = Data("attestation".utf8),
        assertionResult: Data = Data("assertion".utf8)
    ) {
        self.supported = supported
        self.generateKeyFailures = generateKeyFailures
        self.attestationFailures = attestationFailures
        self.assertionFailures = assertionFailures
        self.attestationResult = attestationResult
        self.assertionResult = assertionResult
    }

    func isSupported() async -> Bool { supported }
    func generateKey() async throws -> String {
        generateKeyCount += 1
        if !generateKeyFailures.isEmpty { throw generateKeyFailures.removeFirst() }
        return "generated-key-\(generateKeyCount)"
    }
    func attestKey(keyID _: String, clientDataHash _: Data) async throws -> Data {
        attestationCount += 1
        if !attestationFailures.isEmpty { throw attestationFailures.removeFirst() }
        return attestationResult
    }
    func generateAssertion(keyID _: String, clientDataHash _: Data) async throws -> Data {
        assertionCount += 1
        if !assertionFailures.isEmpty { throw assertionFailures.removeFirst() }
        return assertionResult
    }

    func counts() -> (generateKey: Int, attestation: Int, assertion: Int) {
        (generateKeyCount, attestationCount, assertionCount)
    }
}

private actor SuspendedKeyService: AppAttestServicing {
    private var generationStarted = false
    private var generationReleased = false
    private var generationWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var generateKeyCount = 0
    private var attestationCount = 0

    func isSupported() async -> Bool { true }

    func generateKey() async throws -> String {
        generateKeyCount += 1
        let keyID = "generated-key-\(generateKeyCount)"
        generationStarted = true
        let waiters = generationWaiters
        generationWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withTaskCancellationHandler {
            if !generationReleased {
                await withCheckedContinuation { continuation in
                    releaseContinuation = continuation
                }
            }
            return keyID
        } onCancel: {
            Task { await self.recordCancellation() }
        }
    }

    func attestKey(keyID _: String, clientDataHash _: Data) async throws -> Data {
        attestationCount += 1
        return Data("attestation".utf8)
    }

    func generateAssertion(keyID _: String, clientDataHash _: Data) async throws -> Data {
        Data("assertion".utf8)
    }

    func waitUntilKeyGenerationStarts() async {
        if generationStarted { return }
        await withCheckedContinuation { continuation in
            generationWaiters.append(continuation)
        }
    }

    func finishKeyGeneration() {
        generationReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func waitUntilCancellationIsObserved() async {
        if cancellationObserved { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters.append(continuation)
        }
    }

    private var cancellationObserved = false
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    private func recordCancellation() {
        cancellationObserved = true
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func counts() -> (generateKey: Int, attestation: Int) {
        (generateKeyCount, attestationCount)
    }
}

private actor SuspendedInvalidAssertionService: AppAttestServicing {
    private var generateKeyCount = 0
    private var attestationCount = 0
    private var assertionCount = 0
    private var assertionCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var attestationCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var assertionReleases: [Int: CheckedContinuation<Void, Never>] = [:]
    private var releasedAssertions: Set<Int> = []

    func isSupported() async -> Bool { true }

    func generateKey() async throws -> String {
        generateKeyCount += 1
        return "generated-key-\(generateKeyCount)"
    }

    func attestKey(keyID _: String, clientDataHash _: Data) async throws -> Data {
        attestationCount += 1
        resumeCountWaiters(&attestationCountWaiters, current: attestationCount)
        return Data("attestation".utf8)
    }

    func generateAssertion(keyID _: String, clientDataHash _: Data) async throws -> Data {
        assertionCount += 1
        let ordinal = assertionCount
        resumeCountWaiters(&assertionCountWaiters, current: assertionCount)
        if releasedAssertions.remove(ordinal) == nil {
            await withCheckedContinuation { continuation in
                assertionReleases[ordinal] = continuation
            }
        }
        throw AppAttestOperationError.invalidKey
    }

    func waitUntilAssertionCount(_ expected: Int) async {
        if assertionCount >= expected { return }
        await withCheckedContinuation { continuation in
            assertionCountWaiters.append((expected, continuation))
        }
    }

    func waitUntilAttestationCount(_ expected: Int) async {
        if attestationCount >= expected { return }
        await withCheckedContinuation { continuation in
            attestationCountWaiters.append((expected, continuation))
        }
    }

    func releaseAssertion(_ ordinal: Int) {
        if let continuation = assertionReleases.removeValue(forKey: ordinal) {
            continuation.resume()
        } else {
            releasedAssertions.insert(ordinal)
        }
    }

    func counts() -> (generateKey: Int, attestation: Int, assertion: Int) {
        (generateKeyCount, attestationCount, assertionCount)
    }

    private func resumeCountWaiters(
        _ waiters: inout [(Int, CheckedContinuation<Void, Never>)],
        current: Int
    ) {
        let ready = waiters.filter { $0.0 <= current }
        waiters.removeAll { $0.0 <= current }
        ready.forEach { $0.1.resume() }
    }
}

private extension Array where Element == Task<LatchwayAttestationEvidence, Error> {
    func asyncValues() async throws -> [LatchwayAttestationEvidence] {
        var values: [LatchwayAttestationEvidence] = []
        values.reserveCapacity(count)
        for task in self { values.append(try await task.value) }
        return values
    }
}

private actor SuspendedLoadStateStore: AppAttestStateStoring {
    private var state: LatchwayAppAttestProvider.State?
    private var loadStarted = false
    private var loadReleased = false
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func load() async throws -> LatchwayAppAttestProvider.State? {
        loadStarted = true
        let waiters = loadWaiters
        loadWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if !loadReleased {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
        return state
    }

    func save(_ state: LatchwayAppAttestProvider.State) async throws {
        self.state = state
    }

    func clear() async throws { state = nil }

    func waitUntilLoadStarts() async {
        if loadStarted { return }
        await withCheckedContinuation { continuation in
            loadWaiters.append(continuation)
        }
    }

    func finishLoad() {
        loadReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor SuspendedSaveStateStore: AppAttestStateStoring {
    private var state: LatchwayAppAttestProvider.State?
    private var shouldSuspendNextSave = false
    private var saveStarted = false
    private var saveWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var clears = 0

    func load() async throws -> LatchwayAppAttestProvider.State? { state }

    func save(_ state: LatchwayAppAttestProvider.State) async throws {
        if shouldSuspendNextSave {
            shouldSuspendNextSave = false
            saveStarted = true
            let waiters = saveWaiters
            saveWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
        self.state = state
    }

    func clear() async throws {
        clears += 1
        state = nil
    }

    func suspendNextSave() {
        shouldSuspendNextSave = true
        saveStarted = false
    }

    func waitUntilSaveStarts() async {
        if saveStarted { return }
        await withCheckedContinuation { continuation in
            saveWaiters.append(continuation)
        }
    }

    func finishSave() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func clearCount() -> Int { clears }
}

private actor MemoryStateStore: AppAttestStateStoring {
    private var state: LatchwayAppAttestProvider.State?
    private var loadFailures: Int
    private var saveFailures: Int
    private var clearFailures: Int

    init(
        initial: LatchwayAppAttestProvider.State? = nil,
        loadFailures: Int = 0,
        saveFailures: Int = 0,
        clearFailures: Int = 0
    ) {
        state = initial
        self.loadFailures = loadFailures
        self.saveFailures = saveFailures
        self.clearFailures = clearFailures
    }

    func load() async throws -> LatchwayAppAttestProvider.State? {
        if loadFailures > 0 {
            loadFailures -= 1
            throw StoreFailure.planned
        }
        return state
    }

    func save(_ state: LatchwayAppAttestProvider.State) async throws {
        if saveFailures > 0 {
            saveFailures -= 1
            throw StoreFailure.planned
        }
        self.state = state
    }

    func clear() async throws {
        if clearFailures > 0 {
            clearFailures -= 1
            throw StoreFailure.planned
        }
        state = nil
    }

    func failNextSave() { saveFailures += 1 }

    private enum StoreFailure: Error { case planned }
}

private final class AppAttestPreflightCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
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
