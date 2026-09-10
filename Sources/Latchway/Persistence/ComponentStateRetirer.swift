import Foundation

protocol LatchwayComponentStateRetiring: Sendable {
    func retire(_ component: LatchwayComponentConfiguration) async throws
}

/// Internal dependency-injection sentinel: an unconfigured fixture must never
/// fall back to opening any account-independent Keychain coordinates.
struct LatchwayUnconfiguredComponentStorage: LatchwaySecureDataStoring, LatchwayComponentCredentialStorage {
    func read(account: String) async throws -> Data? { throw LatchwayLifecycleError.configurationConflict }
    func write(_ data: Data, account: String) async throws { throw LatchwayLifecycleError.configurationConflict }
    func delete(account: String) async throws { throw LatchwayLifecycleError.configurationConflict }
    func load() async throws -> LatchwayStoredComponentCredential? { throw LatchwayLifecycleError.configurationConflict }
    func save(_ credential: LatchwayStoredComponentCredential) async throws { throw LatchwayLifecycleError.configurationConflict }
    func clear() async throws { throw LatchwayLifecycleError.configurationConflict }
}
