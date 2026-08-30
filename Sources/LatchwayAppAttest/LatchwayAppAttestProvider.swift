import Foundation
#if !COCOAPODS
import Latchway
#endif
import Security

#if canImport(DeviceCheck)
@preconcurrency import DeviceCheck
#endif

public actor LatchwayAppAttestProvider: LatchwayAttestationProvider {
    struct State: Codable, Sendable, Equatable {
        let keyID: String
        var acceptedByLatchway: Bool
    }

    private let service: any AppAttestServicing
    private let stateStore: any AppAttestStateStoring
    private var state: State?
    private var lastOperation: String?
    private var lifecycleEpoch: UInt64 = 0
    private var creationEpoch: UInt64?
    private var creationGeneration: UInt64 = 0
    private var creationTaskGeneration: UInt64?
    private var creationTask: Task<State, Error>?
    private var acceptanceEpoch: UInt64?
    private var acceptanceGeneration: UInt64 = 0
    private var acceptanceTaskGeneration: UInt64?
    private var acceptanceKeyID: String?
    private var acceptanceTask: Task<Void, Error>?
    private var resetting = false

    /// Creates App Attest state in a caller-managed namespace. The namespace
    /// must be unique for every application, environment, and client runtime;
    /// prefer ``init(applicationID:environment:clientRuntime:)``.
    public init(storageNamespace: String = "default") {
        self.service = SystemAppAttestService()
        self.stateStore = AppAttestKeychainStateStore(namespace: storageNamespace)
    }

    /// Creates runtime-isolated App Attest state for an application
    /// environment. Native iOS and React Native must not share an accepted-key
    /// marker because their installation platforms and DPoP sessions differ.
    public init(
        applicationID: String,
        environment: String,
        clientRuntime: LatchwayClientRuntime = .iOS
    ) {
        self.service = SystemAppAttestService()
        self.stateStore = AppAttestKeychainStateStore(
            namespace: "\(clientRuntime.platformIdentifier).\(applicationID).\(environment)"
        )
    }

    init(service: any AppAttestServicing, stateStore: any AppAttestStateStoring) {
        self.service = service
        self.stateStore = stateStore
    }

    public func evidence(for challenge: LatchwayAttestationChallenge) async throws -> LatchwayAttestationEvidence {
        guard !Task.isCancelled else { throw LatchwayError.cancelled }
        guard !resetting else { throw LatchwayError.cancelled }
        let operationEpoch = lifecycleEpoch
        guard challenge.provider == "app_attest" else { throw LatchwayError.attestationUnavailable }
        guard challenge.clientDataHash.count == 32, challenge.expiresAt > Date() else {
            throw LatchwayError.invalidAttestationBinding
        }
        guard await service.isSupported() else { throw LatchwayError.attestationUnavailable }

        var current = try await loadState(expectedEpoch: operationEpoch)
        if current == nil {
            current = try await createState(expectedEpoch: operationEpoch)
        }
        guard let current else { throw LatchwayError.attestationUnavailable }
        try requireCurrentEpoch(operationEpoch)

        do {
            return try await makeEvidence(
                state: current,
                clientDataHash: challenge.clientDataHash,
                expectedEpoch: operationEpoch
            )
        } catch let error as AppAttestOperationError where error == .invalidKey {
            let recovered = try await recoverState(
                invalidState: current,
                expectedEpoch: operationEpoch
            )
            lastOperation = "key_recovered"
            do {
                return try await makeEvidence(
                    state: recovered,
                    clientDataHash: challenge.clientDataHash,
                    expectedEpoch: operationEpoch
                )
            } catch is CancellationError {
                throw LatchwayError.cancelled
            } catch let error as LatchwayError {
                throw error
            } catch {
                // Recovery is deliberately bounded to one key rotation.
                throw LatchwayError.attestationUnavailable
            }
        } catch is CancellationError {
            throw LatchwayError.cancelled
        } catch let error as LatchwayError {
            throw error
        } catch {
            throw LatchwayError.attestationUnavailable
        }
    }

    public func didAccept(_ evidence: LatchwayAttestationEvidence) async {
        guard !resetting else { return }
        let operationEpoch = lifecycleEpoch
        guard evidence.provider == "app_attest",
              case let .string(keyID)? = evidence.evidence["key_id"],
              var current = try? await loadState(expectedEpoch: operationEpoch),
              current.keyID == keyID,
              !resetting,
              lifecycleEpoch == operationEpoch
        else { return }
        if evidence.evidence["attestation_object"] != nil {
            if current.acceptedByLatchway { return }
            current.acceptedByLatchway = true
            let task: Task<Void, Error>
            let taskGeneration: UInt64
            if let currentTask = acceptanceTask,
               acceptanceEpoch == operationEpoch,
               let currentGeneration = acceptanceTaskGeneration,
               acceptanceKeyID == current.keyID {
                task = currentTask
                taskGeneration = currentGeneration
            } else {
                let stateStore = self.stateStore
                let accepted = current
                task = Task.detached(priority: Task.currentPriority) {
                    try await stateStore.save(accepted)
                }
                acceptanceTask = task
                acceptanceEpoch = operationEpoch
                acceptanceGeneration &+= 1
                taskGeneration = acceptanceGeneration
                acceptanceTaskGeneration = taskGeneration
                acceptanceKeyID = current.keyID
            }
            do {
                try await task.value
                if acceptanceEpoch == operationEpoch,
                   acceptanceTaskGeneration == taskGeneration,
                   acceptanceKeyID == current.keyID {
                    acceptanceTask = nil
                    acceptanceEpoch = nil
                    acceptanceTaskGeneration = nil
                    acceptanceKeyID = nil
                }
                if !resetting, lifecycleEpoch == operationEpoch,
                   creationTask == nil, state?.keyID == current.keyID {
                    state = current
                }
            }
            catch {
                if acceptanceEpoch == operationEpoch,
                   acceptanceTaskGeneration == taskGeneration,
                   acceptanceKeyID == current.keyID {
                    acceptanceTask = nil
                    acceptanceEpoch = nil
                    acceptanceTaskGeneration = nil
                    acceptanceKeyID = nil
                }
                if !resetting, lifecycleEpoch == operationEpoch {
                    lastOperation = "state_persistence_failed"
                }
            }
        }
    }

    public func reset() async throws {
        guard !resetting else { throw LatchwayError.cancelled }
        resetting = true
        lifecycleEpoch &+= 1
        state = nil
        lastOperation = "reset"
        let inFlightCreation = creationTask
        let inFlightAcceptance = acceptanceTask
        inFlightCreation?.cancel()
        inFlightAcceptance?.cancel()
        if let inFlightCreation { _ = try? await inFlightCreation.value }
        if let inFlightAcceptance { _ = try? await inFlightAcceptance.value }
        creationTask = nil
        creationEpoch = nil
        creationTaskGeneration = nil
        acceptanceTask = nil
        acceptanceEpoch = nil
        acceptanceTaskGeneration = nil
        acceptanceKeyID = nil
        do {
            try await stateStore.clear()
            resetting = false
        } catch {
            resetting = false
            throw LatchwayError.keyStorageFailure
        }
    }

    public func status() async -> LatchwayAttestationStatus {
        let supported = await service.isSupported()
        let operationEpoch = lifecycleEpoch
        let current = try? await loadState(expectedEpoch: operationEpoch)
        return LatchwayAttestationStatus(
            support: supported ? .supported : .unsupported,
            keyID: current?.keyID,
            lastOperation: lastOperation
        )
    }

    private func makeEvidence(
        state: State,
        clientDataHash: Data,
        expectedEpoch: UInt64
    ) async throws -> LatchwayAttestationEvidence {
        guard !Task.isCancelled else { throw LatchwayError.cancelled }
        try requireCurrentEpoch(expectedEpoch)
        if state.acceptedByLatchway {
            let assertion = try await service.generateAssertion(keyID: state.keyID, clientDataHash: clientDataHash)
            try Task.checkCancellation()
            try requireCurrentEpoch(expectedEpoch)
            guard (1 ... 65_536).contains(assertion.count) else {
                throw LatchwayError.attestationUnavailable
            }
            lastOperation = "assertion"
            return LatchwayAttestationEvidence(provider: "app_attest", evidence: [
                "key_id": .string(state.keyID),
                "assertion_object": .string(Self.base64URL(assertion)),
                "client_data_hash": .string(Self.base64URL(clientDataHash)),
            ])
        }

        let attestation = try await service.attestKey(keyID: state.keyID, clientDataHash: clientDataHash)
        try Task.checkCancellation()
        try requireCurrentEpoch(expectedEpoch)
        guard (1 ... 65_536).contains(attestation.count) else {
            throw LatchwayError.attestationUnavailable
        }
        lastOperation = "attestation"
        return LatchwayAttestationEvidence(provider: "app_attest", evidence: [
            "key_id": .string(state.keyID),
            "attestation_object": .string(Self.base64URL(attestation)),
            "client_data_hash": .string(Self.base64URL(clientDataHash)),
        ])
    }

    private func loadState(expectedEpoch: UInt64) async throws -> State? {
        try requireCurrentEpoch(expectedEpoch)
        if let state { return state }
        if creationTask != nil, creationEpoch == expectedEpoch { return nil }
        let loaded: State?
        do { loaded = try await stateStore.load() }
        catch { throw LatchwayError.keyStorageFailure }
        try requireCurrentEpoch(expectedEpoch)
        // A key transition may have completed (or become in flight) while the
        // store read was suspended. Never overwrite it with a stale snapshot.
        if let state { return state }
        if creationTask != nil, creationEpoch == expectedEpoch { return nil }
        guard let loaded else { return nil }
        guard (1 ... 1_024).contains(loaded.keyID.utf8.count) else {
            throw LatchwayError.keyStorageFailure
        }
        state = loaded
        return loaded
    }

    private func recoverState(invalidState: State, expectedEpoch: UInt64) async throws -> State {
        try requireCurrentEpoch(expectedEpoch)
        guard !Task.isCancelled else { throw LatchwayError.cancelled }
        // An acceptance marker for the invalid key must finish before its
        // replacement clears storage, otherwise the old marker could land
        // after the new key. The completion path below also refuses to cache
        // the old state once a creation transition is active.
        if let pendingAcceptance = acceptanceTask,
           acceptanceEpoch == expectedEpoch,
           let pendingAcceptanceGeneration = acceptanceTaskGeneration,
           acceptanceKeyID == invalidState.keyID {
            pendingAcceptance.cancel()
            _ = try? await pendingAcceptance.value
            try requireCurrentEpoch(expectedEpoch)
            guard !Task.isCancelled else { throw LatchwayError.cancelled }
            if acceptanceEpoch == expectedEpoch,
               acceptanceTaskGeneration == pendingAcceptanceGeneration,
               acceptanceKeyID == invalidState.keyID {
                acceptanceTask = nil
                acceptanceEpoch = nil
                acceptanceTaskGeneration = nil
                acceptanceKeyID = nil
            }
        }
        if let state, state.keyID != invalidState.keyID {
            return state
        }
        // Reserve the shared transition before the first awaited storage
        // operation. Other stale invalid-key observations will join it instead
        // of clearing a newly persisted replacement key.
        state = nil
        return try await createState(expectedEpoch: expectedEpoch, clearPersistedState: true)
    }

    private func createState(
        expectedEpoch: UInt64,
        clearPersistedState: Bool = false
    ) async throws -> State {
        try requireCurrentEpoch(expectedEpoch)
        guard !Task.isCancelled else { throw LatchwayError.cancelled }
        // Another waiter can populate state after this caller's load returned
        // nil but before it reaches creation. Re-check here so a completed
        // shared creation cannot be followed by a second key generation.
        if let state {
            guard !Task.isCancelled else { throw LatchwayError.cancelled }
            return state
        }
        let task: Task<State, Error>
        let taskGeneration: UInt64
        if let currentTask = creationTask,
           creationEpoch == expectedEpoch,
           let currentGeneration = creationTaskGeneration {
            task = currentTask
            taskGeneration = currentGeneration
        } else {
            let service = self.service
            let stateStore = self.stateStore
            task = Task.detached(priority: Task.currentPriority) {
                if clearPersistedState {
                    do { try await stateStore.clear() }
                    catch is CancellationError { throw LatchwayError.cancelled }
                    catch { throw LatchwayError.keyStorageFailure }
                    guard !Task.isCancelled else { throw LatchwayError.cancelled }
                }
                let keyID: String
                do { keyID = try await service.generateKey() }
                catch is CancellationError { throw LatchwayError.cancelled }
                catch { throw LatchwayError.attestationUnavailable }
                guard (1 ... 1_024).contains(keyID.utf8.count) else {
                    throw LatchwayError.attestationUnavailable
                }
                // Ordinary waiter cancellation does not cancel this shared task,
                // so a successfully generated key is persisted for the next call.
                // reset() explicitly cancels it and waits before clearing storage.
                guard !Task.isCancelled else { throw LatchwayError.cancelled }
                let created = State(keyID: keyID, acceptedByLatchway: false)
                do { try await stateStore.save(created) }
                catch is CancellationError { throw LatchwayError.cancelled }
                catch { throw LatchwayError.keyStorageFailure }
                return created
            }
            creationTask = task
            creationEpoch = expectedEpoch
            creationGeneration &+= 1
            taskGeneration = creationGeneration
            creationTaskGeneration = taskGeneration
        }

        do {
            let created = try await task.value
            try requireCurrentEpoch(expectedEpoch)
            state = created
            lastOperation = "key_created"
            if creationEpoch == expectedEpoch, creationTaskGeneration == taskGeneration {
                creationTask = nil
                creationEpoch = nil
                creationTaskGeneration = nil
            }
            guard !Task.isCancelled else { throw LatchwayError.cancelled }
            return created
        } catch is CancellationError {
            if creationEpoch == expectedEpoch, creationTaskGeneration == taskGeneration {
                creationTask = nil
                creationEpoch = nil
                creationTaskGeneration = nil
            }
            throw LatchwayError.cancelled
        } catch let error as LatchwayError {
            if creationEpoch == expectedEpoch, creationTaskGeneration == taskGeneration {
                creationTask = nil
                creationEpoch = nil
                creationTaskGeneration = nil
            }
            throw error
        } catch {
            if creationEpoch == expectedEpoch, creationTaskGeneration == taskGeneration {
                creationTask = nil
                creationEpoch = nil
                creationTaskGeneration = nil
            }
            throw LatchwayError.attestationUnavailable
        }
    }

    private func requireCurrentEpoch(_ expectedEpoch: UInt64) throws {
        guard !resetting, lifecycleEpoch == expectedEpoch else {
            throw LatchwayError.cancelled
        }
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum AppAttestOperationError: Error, Equatable {
    case unsupported
    case invalidKey
    case invalidInput
    case serverUnavailable
    case failure
}

protocol AppAttestServicing: Sendable {
    func isSupported() async -> Bool
    func generateKey() async throws -> String
    func attestKey(keyID: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(keyID: String, clientDataHash: Data) async throws -> Data
}

private actor SystemAppAttestService: AppAttestServicing {
    #if canImport(DeviceCheck)
    private let service = DCAppAttestService.shared
    #endif

    func isSupported() async -> Bool {
        #if canImport(DeviceCheck)
        return service.isSupported
        #else
        return false
        #endif
    }

    func generateKey() async throws -> String {
        #if canImport(DeviceCheck)
        return try await withCheckedThrowingContinuation { continuation in
            service.generateKey { keyID, error in
                if let keyID { continuation.resume(returning: keyID) }
                else { continuation.resume(throwing: Self.map(error)) }
            }
        }
        #else
        throw AppAttestOperationError.unsupported
        #endif
    }

    func attestKey(keyID: String, clientDataHash: Data) async throws -> Data {
        #if canImport(DeviceCheck)
        return try await withCheckedThrowingContinuation { continuation in
            service.attestKey(keyID, clientDataHash: clientDataHash) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: Self.map(error)) }
            }
        }
        #else
        throw AppAttestOperationError.unsupported
        #endif
    }

    func generateAssertion(keyID: String, clientDataHash: Data) async throws -> Data {
        #if canImport(DeviceCheck)
        return try await withCheckedThrowingContinuation { continuation in
            service.generateAssertion(keyID, clientDataHash: clientDataHash) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: Self.map(error)) }
            }
        }
        #else
        throw AppAttestOperationError.unsupported
        #endif
    }

    private static func map(_ error: Error?) -> AppAttestOperationError {
        #if canImport(DeviceCheck)
        guard let dcError = error as? DCError else { return .failure }
        switch dcError.code {
        case .featureUnsupported: return .unsupported
        case .invalidKey: return .invalidKey
        case .invalidInput: return .invalidInput
        case .serverUnavailable: return .serverUnavailable
        default: return .failure
        }
        #else
        return .unsupported
        #endif
    }
}

protocol AppAttestStateStoring: Sendable {
    func load() async throws -> LatchwayAppAttestProvider.State?
    func save(_ state: LatchwayAppAttestProvider.State) async throws
    func clear() async throws
}

private actor AppAttestKeychainStateStore: AppAttestStateStoring {
    private let service: String
    private let account = "app-attest-state"

    init(namespace: String) {
        service = "dev.latchway.sdk.app-attest.\(namespace)"
    }

    func load() async throws -> LatchwayAppAttestProvider.State? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
            kSecReturnData: kCFBooleanTrue as Any,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw LatchwayError.keyStorageFailure }
        do { return try JSONDecoder().decode(LatchwayAppAttestProvider.State.self, from: data) }
        catch { throw LatchwayError.keyStorageFailure }
    }

    func save(_ state: LatchwayAppAttestProvider.State) async throws {
        let data = try JSONEncoder().encode(state)
        let identity: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
        ]
        let update = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw LatchwayError.keyStorageFailure }
        var insertion = identity
        attributes.forEach { insertion[$0.key] = $0.value }
        guard SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess else { throw LatchwayError.keyStorageFailure }
    }

    func clear() async throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LatchwayError.keyStorageFailure }
    }
}
