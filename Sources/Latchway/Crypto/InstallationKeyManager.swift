import CryptoKit
import Foundation

public actor LatchwayInstallationKeyManager: LatchwayInstallationKey {
    private enum Key {
        case secureEnclave(SecureEnclave.P256.Signing.PrivateKey)
        case software(P256.Signing.PrivateKey)
    }

    private let policy: LatchwaySoftwareKeyFallbackPolicy
    private let store: any LatchwaySecureDataStoring
    private let preferSecureEnclave: Bool
    private let rootKeychainPreflight: @Sendable () throws -> Void
    private var key: Key?
    private var rootKeychainPreflightComplete = false

    public init(
        applicationID: String,
        environment: String,
        rootKeychainAccessGroup: String,
        legacySharedKeychainAccessGroups: [String] = [],
        clientRuntime: LatchwayClientRuntime = .iOS,
        softwareFallbackPolicy: LatchwaySoftwareKeyFallbackPolicy
    ) {
        self.policy = softwareFallbackPolicy
        let service = LatchwayKeychainNamespace.service(
            applicationID: applicationID,
            environment: environment,
            clientRuntime: clientRuntime
        )
        self.store = LatchwayKeychainStore(
            service: service,
            accessGroup: rootKeychainAccessGroup
        )
        self.preferSecureEnclave = true
        self.rootKeychainPreflight = LatchwayRootKeychainPreflight.verifier(
            rootKeychainAccessGroup: rootKeychainAccessGroup,
            legacySharedKeychainAccessGroups: legacySharedKeychainAccessGroups,
            service: service,
            accounts: ["installation-key", "installation-key-kind"]
        )
    }

    init(
        softwareFallbackPolicy: LatchwaySoftwareKeyFallbackPolicy,
        store: any LatchwaySecureDataStoring,
        preferSecureEnclave: Bool,
        rootKeychainPreflight: @escaping @Sendable () throws -> Void = {}
    ) {
        self.policy = softwareFallbackPolicy
        self.store = store
        self.preferSecureEnclave = preferSecureEnclave
        self.rootKeychainPreflight = rootKeychainPreflight
    }

    public func publicJWK() async throws -> LatchwayPublicJWK {
        try ensureRootKeychainPreflight()
        let representation: Data
        switch try await loadOrCreate() {
        case let .secureEnclave(key): representation = key.publicKey.x963Representation
        case let .software(key): representation = key.publicKey.x963Representation
        }
        guard representation.count == 65, representation.first == 0x04 else { throw LatchwayError.keyStorageFailure }
        return LatchwayPublicJWK(
            x: Base64URL.encode(representation[1 ..< 33]),
            y: Base64URL.encode(representation[33 ..< 65])
        )
    }

    public func sign(_ message: Data) async throws -> Data {
        try ensureRootKeychainPreflight()
        let digest = SHA256.hash(data: message)
        do {
            switch try await loadOrCreate() {
            case let .secureEnclave(key): return try key.signature(for: digest).rawRepresentation
            case let .software(key): return try key.signature(for: digest).rawRepresentation
            }
        } catch is LatchwayError { throw LatchwayError.keyStorageFailure }
        catch { throw LatchwayError.keyStorageFailure }
    }

    public func storage() async -> LatchwayKeyStorage {
        do {
            try ensureRootKeychainPreflight()
            guard let existing = try await loadExisting() else { return .unavailable }
            switch existing {
            case .secureEnclave: return .secureEnclave
            case .software: return .keychainSoftware
            }
        } catch {
            return .unavailable
        }
    }

    public func reset() async throws {
        try ensureRootKeychainPreflight()
        key = nil
        try await store.delete(account: "installation-key")
        try await store.delete(account: "installation-key-kind")
    }

    private func loadOrCreate() async throws -> Key {
        if let existing = try await loadExisting() { return existing }

        if preferSecureEnclave, SecureEnclave.isAvailable {
            do {
                let created = try SecureEnclave.P256.Signing.PrivateKey()
                try await persist(created.dataRepresentation, kind: "secure_enclave")
                let result = Key.secureEnclave(created)
                key = result
                return result
            } catch {
                if policy == .disallow { throw LatchwayError.secureEnclaveUnavailable }
            }
        } else if policy == .disallow {
            throw LatchwayError.secureEnclaveUnavailable
        }

        let created = P256.Signing.PrivateKey()
        try await persist(created.rawRepresentation, kind: "keychain_software")
        let result = Key.software(created)
        key = result
        return result
    }

    private func loadExisting() async throws -> Key? {
        if let key { return key }
        let kindData = try await store.read(account: "installation-key-kind")
        let representation = try await store.read(account: "installation-key")
        guard kindData != nil || representation != nil else { return nil }
        guard let kindData,
              let kind = String(data: kindData, encoding: .utf8),
              let representation
        else {
            try await reset()
            return nil
        }
        do {
            let restored: Key
            if kind == "secure_enclave" {
                restored = .secureEnclave(
                    try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: representation)
                )
            } else if kind == "keychain_software", policy != .disallow {
                restored = .software(try P256.Signing.PrivateKey(rawRepresentation: representation))
            } else {
                throw LatchwayError.keyStorageFailure
            }
            key = restored
            return restored
        } catch {
            try await reset()
            return nil
        }
    }

    private func persist(_ representation: Data, kind: String) async throws {
        try await store.write(representation, account: "installation-key")
        do {
            try await store.write(Data(kind.utf8), account: "installation-key-kind")
        } catch {
            try? await store.delete(account: "installation-key")
            throw error
        }
    }

    private func ensureRootKeychainPreflight() throws {
        guard !rootKeychainPreflightComplete else { return }
        try rootKeychainPreflight()
        rootKeychainPreflightComplete = true
    }
}
