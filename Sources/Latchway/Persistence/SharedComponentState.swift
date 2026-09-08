import Foundation
import Security

/// Non-secret handoff for one explicit account activation. Persist this only in
/// an app-group location authorized for the intended extension. It contains no
/// root credential, identity token, user identifier, or private key material.
/// An extension must receive a new handoff after logout; old handles stay terminal.
public struct LatchwayComponentAccount: Codable, Sendable, Equatable {
    public let generationID: UUID
    let appScope: String
    let accountScope: String

    init(generationID: UUID, appScope: String, accountScope: String) {
        self.generationID = generationID
        self.appScope = appScope
        self.accountScope = accountScope
    }

    func validate(_ configuration: LatchwayConfiguration) throws {
        let url = try LatchwayAppIdentity.canonicalURL(configuration.baseURL)
        guard appScope == LatchwayAppIdentity.digest([url.absoluteString,
            configuration.applicationID, configuration.environment]),
            accountScope.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
        else { throw LatchwayLifecycleError.configurationConflict }
    }

    func service(_ component: LatchwayComponentConfiguration) -> String {
        "dev.latchway.shared.v3.component.\(LatchwayAppIdentity.digest([appScope, accountScope, component.definitionID, component.kind]))"
    }
}

struct LatchwayRevisionedValue: Sendable {
    let revision: Data
    let data: Data
}

/// Implementations must compare and replace in one storage transaction. A plain
/// read followed by an unconditional write is not an implementation of this API.
protocol LatchwayRevisionedRecords: Sendable {
    func read() throws -> LatchwayRevisionedValue?
    func replace(expected: Data?, value: LatchwayRevisionedValue) throws -> Bool
}

struct LatchwayKeychainRevisionedRecords: LatchwayRevisionedRecords {
    let service: String
    let accessGroup: String
    private var identity: [CFString: Any] {
        var query = LatchwayKeychainQuery.identity(service: service,
            account: "component-state-v3", accessGroup: accessGroup,
            synchronizable: kCFBooleanFalse as Any)
        query[kSecUseDataProtectionKeychain] = true
        return query
    }

    func read() throws -> LatchwayRevisionedValue? {
        var query = identity
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecReturnData] = true
        query[kSecReturnAttributes] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let item = result as? [String: Any],
              let data = item[kSecValueData as String] as? Data,
              let revision = item[kSecAttrGeneric as String] as? Data, revision.count == 16
        else { throw LatchwayLifecycleError.cleanupRequired }
        return .init(revision: revision, data: data)
    }

    func replace(expected: Data?, value: LatchwayRevisionedValue) throws -> Bool {
        var query = identity
        let attributes: [CFString: Any] = [kSecValueData: value.data,
            kSecAttrGeneric: value.revision,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status: OSStatus
        if let expected {
            query[kSecAttrGeneric] = expected
            status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound { return false }
        } else {
            attributes.forEach { query[$0.key] = $0.value }
            status = SecItemAdd(query as CFDictionary, nil)
            if status == errSecDuplicateItem { return false }
        }
        guard status == errSecSuccess else { throw LatchwayLifecycleError.cleanupRequired }
        return true
    }
}

/// A single, cross-process CAS envelope holds the component's generation fence,
/// delegated credential and its own key representation. Retirement atomically
/// erases credentials and changes the revision. A stale writer can neither add
/// a deleted item nor overwrite that tombstone. Root credentials never enter it.
struct LatchwaySharedComponentState: Sendable {
    struct Envelope: Codable {
        var version = 1
        var generation: UUID
        var retired: Bool
        var values: [String: Data]
    }
    let records: any LatchwayRevisionedRecords
    let generation: UUID

    init(account: LatchwayComponentAccount, component: LatchwayComponentConfiguration) {
        records = LatchwayKeychainRevisionedRecords(service: account.service(component),
            accessGroup: component.keychainAccessGroup)
        generation = account.generationID
    }

    init(records: any LatchwayRevisionedRecords, generation: UUID) {
        self.records = records
        self.generation = generation
    }

    func initialize() throws {
        try mutate { current in
            if let current, current.generation == generation {
                guard !current.retired else { throw LatchwayLifecycleError.loggedOut }
                return current
            }
            guard current == nil || current!.retired else { throw LatchwayLifecycleError.cleanupRequired }
            // Only journal-serialized verified root activation calls this.
            // Retained keys belong to this exact account namespace; they are
            // never reassigned to another account or read by retired handles.
            return Envelope(generation: generation, retired: false, values: current?.values ?? [:])
        }
    }

    func check() throws { _ = try active() }

    func retire() throws {
        try mutate { current in
            // An old logout never retires a replacement generation. Missing
            // state receives a tombstone before any late provisioning callback.
            if let current, current.generation != generation { return current }
            return Envelope(generation: generation, retired: true,
                values: current?.values.filter { $0.key != "credential" } ?? [:])
        }
    }

    func evictRetiredKeys() throws {
        try mutate { current in
            guard let current else { return Envelope(generation: generation, retired: true, values: [:]) }
            guard current.retired else { throw LatchwayLifecycleError.cleanupRequired }
            return Envelope(generation: current.generation, retired: true, values: [:])
        }
    }

    func read(_ name: String) throws -> Data? { try active().values[name] }

    func write(_ data: Data?, name: String) throws {
        try mutate { current in
            guard var current, current.generation == generation, !current.retired else {
                throw LatchwayLifecycleError.loggedOut
            }
            current.values[name] = data
            return current
        }
    }

    func writeCredential(_ data: Data?, replacing expected: Data?) throws {
        try mutate { current in
            guard var current, current.generation == generation, !current.retired else {
                throw LatchwayLifecycleError.loggedOut
            }
            guard current.values["credential"] == expected else {
                // Another process advanced the rotating chain. Never replace
                // its newer token with this delayed response.
                throw LatchwayLifecycleError.cleanupRequired
            }
            current.values["credential"] = data
            return current
        }
    }

    private func active() throws -> Envelope {
        guard let value = try records.read() else { throw LatchwayLifecycleError.loggedOut }
        let envelope = try decode(value.data)
        guard envelope.generation == generation, !envelope.retired else { throw LatchwayLifecycleError.loggedOut }
        return envelope
    }

    private func decode(_ data: Data) throws -> Envelope {
        guard !data.isEmpty, data.count <= 131_072,
              (try? StrictJSON.validate(data)) != nil,
              let shape = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(shape.keys) == ["version", "generation", "retired", "values"],
              let value = try? JSONDecoder().decode(Envelope.self, from: data), value.version == 1,
              Set(value.values.keys).isSubset(of: ["credential", "component-key", "component-key-kind"]),
              !value.retired || value.values["credential"] == nil else { throw LatchwayLifecycleError.cleanupRequired }
        return value
    }

    private func mutate(_ update: (Envelope?) throws -> Envelope) throws {
        for _ in 0..<32 {
            let previous = try records.read()
            let next = try update(previous.map { try decode($0.data) })
            let data = try JSONEncoder().encode(next)
            guard data.count <= 131_072 else { throw LatchwayLifecycleError.cleanupRequired }
            var uuid = UUID().uuid
            let revision = withUnsafeBytes(of: &uuid) { Data($0) }
            if try records.replace(expected: previous?.revision, value: .init(revision: revision, data: data)) { return }
        }
        throw LatchwayLifecycleError.cleanupRequired
    }
}

actor LatchwaySharedComponentCredentialStorage: LatchwayComponentCredentialStorage {
    let state: LatchwaySharedComponentState
    private var observedCredential: Data?
    private var hasLoaded = false
    init(state: LatchwaySharedComponentState) { self.state = state }
    func load() async throws -> LatchwayStoredComponentCredential? {
        let stored = try state.read("credential")
        observedCredential = stored
        hasLoaded = true
        guard let data = stored else { return nil }
        guard let credential = try? JSONDecoder().decode(LatchwayStoredComponentCredential.self, from: data)
        else { throw LatchwayLifecycleError.cleanupRequired }
        return credential
    }
    func save(_ credential: LatchwayStoredComponentCredential) async throws {
        if !hasLoaded { observedCredential = try state.read("credential"); hasLoaded = true }
        let encoded = try JSONEncoder().encode(credential)
        try state.writeCredential(encoded, replacing: observedCredential)
        observedCredential = encoded
    }
    func clear() async throws {
        if !hasLoaded { observedCredential = try state.read("credential"); hasLoaded = true }
        try state.writeCredential(nil, replacing: observedCredential)
        observedCredential = nil
        hasLoaded = true
    }
}

struct LatchwaySharedComponentKeyStorage: LatchwaySecureDataStoring {
    let state: LatchwaySharedComponentState
    func read(account: String) async throws -> Data? { try state.read(account) }
    func write(_ data: Data, account: String) async throws { try state.write(data, name: account) }
    func delete(account: String) async throws { try state.write(nil, name: account) }
}
