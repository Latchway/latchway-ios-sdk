import Foundation

/// A root-private index of component Keychain coordinates.
///
/// The registry deliberately stores only public configuration. Component
/// credentials and private-key material remain in their component-specific
/// access groups. Keeping these coordinates in the root access group lets a
/// later process finish local sign-out cleanup without asking JavaScript or the
/// application to remember every descriptor.
protocol LatchwayComponentRegistry: Sendable {
    func components() async throws -> [LatchwayComponentConfiguration]
    func register(_ component: LatchwayComponentConfiguration) async throws
    func unregister(_ component: LatchwayComponentConfiguration) async throws
}

actor LatchwayKeychainComponentRegistry: LatchwayComponentRegistry {
    static let account = "component-registry"

    private let store: any LatchwaySecureDataStoring
    private let rootKeychainPreflight: @Sendable () throws -> Void
    private let mutex: LatchwayComponentRegistryMutex
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var rootKeychainPreflightComplete = false

    init(
        applicationID: String,
        environment: String,
        rootKeychainAccessGroup: String,
        legacySharedKeychainAccessGroups: [String],
        clientRuntime: LatchwayClientRuntime
    ) {
        let service = LatchwayKeychainNamespace.service(
            applicationID: applicationID,
            environment: environment,
            clientRuntime: clientRuntime
        )
        self.store = LatchwayKeychainStore(
            service: service,
            accessGroup: rootKeychainAccessGroup
        )
        self.mutex = LatchwayComponentRegistryLockPool.shared.mutex(
            for: "\(service)|\(rootKeychainAccessGroup)"
        )
        self.rootKeychainPreflight = LatchwayRootKeychainPreflight.verifier(
            rootKeychainAccessGroup: rootKeychainAccessGroup,
            legacySharedKeychainAccessGroups: legacySharedKeychainAccessGroups,
            service: service,
            accounts: [Self.account]
        )
        encoder.outputFormatting = [.sortedKeys]
    }

    init(
        store: any LatchwaySecureDataStoring,
        rootKeychainPreflight: @escaping @Sendable () throws -> Void = {},
        lockIdentity: String = UUID().uuidString
    ) {
        self.store = store
        self.rootKeychainPreflight = rootKeychainPreflight
        self.mutex = LatchwayComponentRegistryLockPool.shared.mutex(for: lockIdentity)
        encoder.outputFormatting = [.sortedKeys]
    }

    func components() async throws -> [LatchwayComponentConfiguration] {
        await mutex.acquire()
        do {
            try ensureRootKeychainPreflight()
            let result = try await loadEnvelope().entries.map { try $0.configuration() }
            await mutex.release()
            return result
        } catch {
            await mutex.release()
            throw error
        }
    }

    func register(_ component: LatchwayComponentConfiguration) async throws {
        try component.validateForContainingApplication()
        await mutex.acquire()
        do {
            try ensureRootKeychainPreflight()
            var entries = try await loadEnvelope().entries
            let replacement = RegisteredComponent(component)
            entries.removeAll { $0.storageCoordinate == replacement.storageCoordinate }
            entries.append(replacement)
            try await persist(entries)
            await mutex.release()
        } catch {
            await mutex.release()
            throw error
        }
    }

    func unregister(_ component: LatchwayComponentConfiguration) async throws {
        try component.validateForContainingApplication()
        await mutex.acquire()
        do {
            try ensureRootKeychainPreflight()
            var entries = try await loadEnvelope().entries
            let coordinate = RegisteredComponent(component).storageCoordinate
            entries.removeAll { $0.storageCoordinate == coordinate }
            try await persist(entries)
            await mutex.release()
        } catch {
            await mutex.release()
            throw error
        }
    }

    private func loadEnvelope() async throws -> Envelope {
        let data: Data
        do {
            guard let stored = try await store.read(account: Self.account) else {
                return Envelope(version: 1, entries: [])
            }
            data = stored
        } catch let error as LatchwayError {
            throw error
        } catch {
            throw LatchwayError.keyStorageFailure
        }

        guard !data.isEmpty, data.count <= Self.maximumEncodedBytes,
              (try? StrictJSON.validate(data)) != nil,
              Self.hasExactShape(data),
              let envelope = try? decoder.decode(Envelope.self, from: data),
              envelope.version == 1,
              envelope.entries.count <= Self.maximumEntries
        else { throw LatchwayError.keyStorageFailure }

        var coordinates = Set<RegisteredComponent.StorageCoordinate>()
        do {
            for entry in envelope.entries {
                _ = try entry.configuration()
                guard coordinates.insert(entry.storageCoordinate).inserted else {
                    throw LatchwayError.keyStorageFailure
                }
            }
        } catch {
            throw LatchwayError.keyStorageFailure
        }
        return envelope
    }

    private static func hasExactShape(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["version", "entries"],
              let entries = object["entries"] as? [[String: Any]],
              entries.allSatisfy({ entry in
                  Set(entry.keys) == [
                      "definitionID", "kind", "keychainAccessGroup", "requestedFeatures",
                  ]
              })
        else { return false }
        return true
    }

    private func persist(_ entries: [RegisteredComponent]) async throws {
        let sorted = entries.sorted {
            if $0.definitionID != $1.definitionID { return $0.definitionID < $1.definitionID }
            if $0.kind != $1.kind { return $0.kind < $1.kind }
            return $0.keychainAccessGroup < $1.keychainAccessGroup
        }
        guard sorted.count <= Self.maximumEntries,
              let data = try? encoder.encode(Envelope(version: 1, entries: sorted)),
              data.count <= Self.maximumEncodedBytes
        else { throw LatchwayError.keyStorageFailure }

        do {
            if sorted.isEmpty {
                try await store.delete(account: Self.account)
            } else {
                try await store.write(data, account: Self.account)
            }
        } catch let error as LatchwayError {
            throw error
        } catch {
            throw LatchwayError.keyStorageFailure
        }
    }

    private func ensureRootKeychainPreflight() throws {
        guard !rootKeychainPreflightComplete else { return }
        try rootKeychainPreflight()
        rootKeychainPreflightComplete = true
    }

    private static let maximumEntries = 256
    private static let maximumEncodedBytes = 65_536
}

private struct Envelope: Codable {
    let version: Int
    let entries: [RegisteredComponent]
}

private struct RegisteredComponent: Codable {
    struct StorageCoordinate: Hashable {
        let definitionID: String
        let kind: String
        let keychainAccessGroup: String
    }

    let definitionID: String
    let kind: String
    let keychainAccessGroup: String
    let requestedFeatures: [String]

    init(_ component: LatchwayComponentConfiguration) {
        definitionID = component.definitionID
        kind = component.kind
        keychainAccessGroup = component.keychainAccessGroup
        requestedFeatures = component.requestedFeatures
    }

    var storageCoordinate: StorageCoordinate {
        StorageCoordinate(
            definitionID: definitionID,
            kind: kind,
            keychainAccessGroup: keychainAccessGroup
        )
    }

    func configuration() throws -> LatchwayComponentConfiguration {
        let value = LatchwayComponentConfiguration(
            definitionID: definitionID,
            kind: kind,
            keychainAccessGroup: keychainAccessGroup,
            requestedFeatures: requestedFeatures
        )
        try value.validateForContainingApplication()
        return value
    }
}

extension LatchwayComponentConfiguration {
    func validateForContainingApplication() throws {
        for (label, value) in [
            ("definitionID", definitionID),
            ("kind", kind),
        ] {
            guard value.range(of: "^[a-z][a-z0-9_-]{0,62}$", options: .regularExpression) != nil else {
                throw LatchwayComponentError.invalidConfiguration(
                    "\(label) must be a valid Latchway identifier"
                )
            }
        }
        guard keychainAccessGroup.range(
            of: "^[A-Za-z0-9._-]{1,255}$",
            options: .regularExpression
        ) != nil else {
            throw LatchwayComponentError.invalidConfiguration(
                "keychainAccessGroup must be one fully resolved signed-entitlement access group"
            )
        }
        guard !requestedFeatures.isEmpty,
              requestedFeatures.count <= 256,
              Set(requestedFeatures).count == requestedFeatures.count,
              requestedFeatures.allSatisfy({ feature in
                  feature.range(of: "^[a-z][a-z0-9_-]{0,62}$", options: .regularExpression) != nil
              })
        else {
            throw LatchwayComponentError.invalidConfiguration(
                "requestedFeatures must contain unique Latchway feature identifiers"
            )
        }
    }
}

/// Executes best-effort cleanup for every durable and caller-supplied
/// descriptor. A durable entry is removed only after its component credential
/// and key have both been retired, so a transient Keychain failure remains
/// retryable on a later launch.
enum LatchwayComponentFamilyRetirement {
    static func retireAll(
        registry: any LatchwayComponentRegistry,
        including explicitComponents: [LatchwayComponentConfiguration],
        retire: @escaping @Sendable (LatchwayComponentConfiguration) async throws -> Void
    ) async throws {
        var firstError: (any Error)?
        var registered: [LatchwayComponentConfiguration] = []
        do {
            registered = try await registry.components()
        } catch {
            firstError = error
        }

        for component in registered {
            do {
                try await retire(component)
                try await registry.unregister(component)
            } catch {
                firstError = firstError ?? error
            }
        }

        let registeredCoordinates = Set(registered.map(StorageCoordinate.init))
        for component in explicitComponents
        where !registeredCoordinates.contains(StorageCoordinate(component)) {
            do {
                try await retire(component)
            } catch {
                firstError = firstError ?? error
            }
        }

        if let firstError { throw firstError }
    }

    private struct StorageCoordinate: Hashable {
        let definitionID: String
        let kind: String
        let keychainAccessGroup: String

        init(_ component: LatchwayComponentConfiguration) {
            definitionID = component.definitionID
            kind = component.kind
            keychainAccessGroup = component.keychainAccessGroup
        }
    }
}
