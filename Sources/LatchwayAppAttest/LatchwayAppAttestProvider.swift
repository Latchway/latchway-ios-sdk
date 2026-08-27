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
        try Task.checkCancellation()
        guard challenge.provider == "app_attest" else { throw LatchwayError.attestationUnavailable }
        guard challenge.clientDataHash.count == 32, challenge.expiresAt > Date() else {
            throw LatchwayError.invalidAttestationBinding
        }
        guard await service.isSupported() else { throw LatchwayError.attestationUnavailable }

        var current = try await loadState()
        if current == nil {
            current = try await createState()
        }
        guard let current else { throw LatchwayError.attestationUnavailable }

        do {
            return try await makeEvidence(state: current, clientDataHash: challenge.clientDataHash)
        } catch let error as AppAttestOperationError where error == .invalidKey {
            do { try await stateStore.clear() }
            catch { throw LatchwayError.keyStorageFailure }
            state = nil
            let recovered = try await createState()
            lastOperation = "key_recovered"
            do {
                return try await makeEvidence(state: recovered, clientDataHash: challenge.clientDataHash)
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
        guard evidence.provider == "app_attest",
              case let .string(keyID)? = evidence.evidence["key_id"],
              var current = try? await loadState(),
              current.keyID == keyID
        else { return }
        if evidence.evidence["attestation_object"] != nil {
            current.acceptedByLatchway = true
            state = current
            do { try await stateStore.save(current) }
            catch { lastOperation = "state_persistence_failed" }
        }
    }

    public func reset() async throws {
        state = nil
        lastOperation = "reset"
        do { try await stateStore.clear() }
        catch { throw LatchwayError.keyStorageFailure }
    }

    public func status() async -> LatchwayAttestationStatus {
        let supported = await service.isSupported()
        let current = try? await loadState()
        return LatchwayAttestationStatus(
            support: supported ? .supported : .unsupported,
            keyID: current?.keyID,
            lastOperation: lastOperation
        )
    }

    private func makeEvidence(state: State, clientDataHash: Data) async throws -> LatchwayAttestationEvidence {
        if state.acceptedByLatchway {
            let assertion = try await service.generateAssertion(keyID: state.keyID, clientDataHash: clientDataHash)
            try Task.checkCancellation()
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

    private func loadState() async throws -> State? {
        if let state { return state }
        let loaded: State?
        do { loaded = try await stateStore.load() }
        catch { throw LatchwayError.keyStorageFailure }
        guard let loaded else { return nil }
        guard (1 ... 1_024).contains(loaded.keyID.utf8.count) else {
            throw LatchwayError.keyStorageFailure
        }
        state = loaded
        return loaded
    }

    private func createState() async throws -> State {
        let keyID: String
        do {
            keyID = try await service.generateKey()
            try Task.checkCancellation()
        }
        catch is CancellationError { throw LatchwayError.cancelled }
        catch { throw LatchwayError.attestationUnavailable }
        guard (1 ... 1_024).contains(keyID.utf8.count) else {
            throw LatchwayError.attestationUnavailable
        }
        let created = State(keyID: keyID, acceptedByLatchway: false)
        do { try await stateStore.save(created) }
        catch { throw LatchwayError.keyStorageFailure }
        state = created
        lastOperation = "key_created"
        return created
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
