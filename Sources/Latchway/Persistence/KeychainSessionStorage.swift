import Foundation

public actor LatchwayKeychainSessionStorage: LatchwaySessionStorage {
    private let store: LatchwayKeychainStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        applicationID: String,
        environment: String,
        clientRuntime: LatchwayClientRuntime = .iOS
    ) {
        self.store = LatchwayKeychainStore(service: LatchwayKeychainNamespace.service(
            applicationID: applicationID,
            environment: environment,
            clientRuntime: clientRuntime
        ))
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func load() async throws -> LatchwayStoredSession? {
        guard let data = try await store.read(account: "session") else { return nil }
        do { return try decoder.decode(LatchwayStoredSession.self, from: data) }
        catch {
            try? await store.delete(account: "session")
            throw LatchwayError.keyStorageFailure
        }
    }

    public func save(_ session: LatchwayStoredSession) async throws {
        do { try await store.write(try encoder.encode(session), account: "session") }
        catch { throw LatchwayError.keyStorageFailure }
    }

    public func clear() async throws {
        try await store.delete(account: "session")
    }
}
