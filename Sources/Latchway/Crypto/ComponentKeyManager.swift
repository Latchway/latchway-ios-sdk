import CryptoKit
import Foundation

/// Owns the DPoP key for one configured client component.
///
/// The private key is never returned. Its persisted representation and the
/// component's rotating grant share the component-specific Keychain access
/// group selected by the containing application.
public actor LatchwayComponentKeyManager: LatchwayInstallationKey {
    private enum Key {
        case secureEnclave(SecureEnclave.P256.Signing.PrivateKey)
        case software(P256.Signing.PrivateKey)
    }

    private let policy: LatchwaySoftwareKeyFallbackPolicy
    private let store: any LatchwaySecureDataStoring
    private let preferSecureEnclave: Bool
    private let allowCreation: Bool

    public init(
        applicationID: String,
        environment: String,
        definitionID: String,
        keychainAccessGroup: String,
        softwareFallbackPolicy: LatchwaySoftwareKeyFallbackPolicy = .disallow
    ) {
        policy = softwareFallbackPolicy
        store = LatchwayKeychainStore(
            service: LatchwayKeychainNamespace.componentService(
                applicationID: applicationID,
                environment: environment,
                definitionID: definitionID
            ),
            accessGroup: keychainAccessGroup
        )
        preferSecureEnclave = true
        allowCreation = true
    }

    init(
        applicationID: String,
        environment: String,
        definitionID: String,
        keychainAccessGroup: String,
        softwareFallbackPolicy: LatchwaySoftwareKeyFallbackPolicy,
        allowCreation: Bool
    ) {
        policy = softwareFallbackPolicy
        store = LatchwayKeychainStore(
            service: LatchwayKeychainNamespace.componentService(
                applicationID: applicationID,
                environment: environment,
                definitionID: definitionID
            ),
            accessGroup: keychainAccessGroup
        )
        preferSecureEnclave = true
        self.allowCreation = allowCreation
    }

    init(
        softwareFallbackPolicy: LatchwaySoftwareKeyFallbackPolicy,
        store: any LatchwaySecureDataStoring,
        preferSecureEnclave: Bool,
        allowCreation: Bool = true
    ) {
        policy = softwareFallbackPolicy
        self.store = store
        self.preferSecureEnclave = preferSecureEnclave
        self.allowCreation = allowCreation
    }

    public func publicJWK() async throws -> LatchwayPublicJWK {
        let representation: Data
        switch try await loadOrCreate() {
        case let .secureEnclave(key): representation = key.publicKey.x963Representation
        case let .software(key): representation = key.publicKey.x963Representation
        }
        guard representation.count == 65, representation.first == 0x04 else {
            throw LatchwayComponentError.componentKeyUnavailable
        }
        return LatchwayPublicJWK(
            x: Base64URL.encode(representation[1 ..< 33]),
            y: Base64URL.encode(representation[33 ..< 65])
        )
    }

    public func sign(_ message: Data) async throws -> Data {
        let digest = SHA256.hash(data: message)
        do {
            switch try await loadOrCreate() {
            case let .secureEnclave(key): return try key.signature(for: digest).rawRepresentation
            case let .software(key): return try key.signature(for: digest).rawRepresentation
            }
        } catch let error as LatchwayComponentError {
            throw error
        } catch {
            throw LatchwayComponentError.componentKeyUnavailable
        }
    }

    public func storage() async -> LatchwayKeyStorage {
        do {
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
        do {
            try await store.delete(account: "component-key")
            try await store.delete(account: "component-key-kind")
        } catch {
            throw LatchwayComponentError.keychainAccessGroupUnavailable
        }
    }

    private func loadOrCreate() async throws -> Key {
        if let existing = try await loadExisting() { return existing }
        guard allowCreation else {
            throw LatchwayComponentError.componentKeyUnavailable
        }

        if preferSecureEnclave, SecureEnclave.isAvailable {
            do {
                let created = try SecureEnclave.P256.Signing.PrivateKey()
                try await persist(created.dataRepresentation, kind: "secure_enclave")
                return .secureEnclave(created)
            } catch let error as LatchwayComponentError {
                throw error
            } catch {
                if policy == .disallow {
                    throw LatchwayComponentError.componentKeyUnavailable
                }
            }
        } else if policy == .disallow {
            throw LatchwayComponentError.componentKeyUnavailable
        }

        let created = P256.Signing.PrivateKey()
        try await persist(created.rawRepresentation, kind: "keychain_software")
        return .software(created)
    }

    private func loadExisting() async throws -> Key? {
        let kindData: Data?
        let representation: Data?
        do {
            kindData = try await store.read(account: "component-key-kind")
            representation = try await store.read(account: "component-key")
        } catch {
            throw LatchwayComponentError.keychainAccessGroupUnavailable
        }
        guard kindData != nil || representation != nil else { return nil }
        guard let kindData,
              let kind = String(data: kindData, encoding: .utf8),
              let representation
        else {
            if allowCreation {
                try await reset()
                return nil
            }
            throw LatchwayComponentError.componentKeyUnavailable
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
                throw LatchwayComponentError.componentKeyUnavailable
            }
            return restored
        } catch {
            if allowCreation {
                try await reset()
                return nil
            }
            throw LatchwayComponentError.componentKeyUnavailable
        }
    }

    private func persist(_ representation: Data, kind: String) async throws {
        do {
            try await store.write(representation, account: "component-key")
            do {
                try await store.write(Data(kind.utf8), account: "component-key-kind")
            } catch {
                try? await store.delete(account: "component-key")
                throw error
            }
        } catch {
            throw LatchwayComponentError.keychainAccessGroupUnavailable
        }
    }
}
