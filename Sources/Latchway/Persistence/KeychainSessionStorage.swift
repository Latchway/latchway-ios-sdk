import Foundation

public actor LatchwayKeychainSessionStorage: LatchwaySessionStorage {
    private let store: any LatchwaySecureDataStoring
    private let rootKeychainPreflight: @Sendable () throws -> Void
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var rootKeychainPreflightComplete = false

    public init(
        applicationID: String,
        environment: String,
        rootKeychainAccessGroup: String,
        legacySharedKeychainAccessGroups: [String] = [],
        clientRuntime: LatchwayClientRuntime = .iOS
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
        self.rootKeychainPreflight = LatchwayRootKeychainPreflight.verifier(
            rootKeychainAccessGroup: rootKeychainAccessGroup,
            legacySharedKeychainAccessGroups: legacySharedKeychainAccessGroups,
            service: service,
            accounts: ["session"]
        )
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    init(
        store: any LatchwaySecureDataStoring,
        rootKeychainPreflight: @escaping @Sendable () throws -> Void
    ) {
        self.store = store
        self.rootKeychainPreflight = rootKeychainPreflight
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func load() async throws -> LatchwayStoredSession? {
        try ensureRootKeychainPreflight()
        guard let data = try await store.read(account: "session") else { return nil }
        do { return try decoder.decode(LatchwayStoredSession.self, from: data) }
        catch {
            try? await store.delete(account: "session")
            throw LatchwayError.keyStorageFailure
        }
    }

    public func save(_ session: LatchwayStoredSession) async throws {
        try ensureRootKeychainPreflight()
        do { try await store.write(try encoder.encode(session), account: "session") }
        catch { throw LatchwayError.keyStorageFailure }
    }

    public func clear() async throws {
        try ensureRootKeychainPreflight()
        try await store.delete(account: "session")
    }

    private func ensureRootKeychainPreflight() throws {
        guard !rootKeychainPreflightComplete else { return }
        try rootKeychainPreflight()
        rootKeychainPreflightComplete = true
    }
}
