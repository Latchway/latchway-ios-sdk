import Foundation

actor LatchwayKeychainComponentStorage: LatchwayComponentCredentialStorage {
    private let store: LatchwayKeychainStore
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        applicationID: String,
        environment: String,
        definitionID: String,
        accessGroup: String
    ) {
        store = LatchwayKeychainStore(
            service: LatchwayKeychainNamespace.componentService(
                applicationID: applicationID,
                environment: environment,
                definitionID: definitionID
            ),
            accessGroup: accessGroup
        )
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() async throws -> LatchwayStoredComponentCredential? {
        guard let data = try await store.read(account: "component-credential") else { return nil }
        do {
            return try decoder.decode(LatchwayStoredComponentCredential.self, from: data)
        } catch {
            try? await store.delete(account: "component-credential")
            throw LatchwayComponentError.componentNotProvisioned
        }
    }

    func save(_ credential: LatchwayStoredComponentCredential) async throws {
        do {
            try await store.write(try encoder.encode(credential), account: "component-credential")
        } catch {
            throw LatchwayComponentError.keychainAccessGroupUnavailable
        }
    }

    func clear() async throws {
        do {
            try await store.delete(account: "component-credential")
        } catch {
            throw LatchwayComponentError.keychainAccessGroupUnavailable
        }
    }
}
