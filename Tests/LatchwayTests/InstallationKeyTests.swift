import Foundation
@testable import Latchway
import XCTest

final class InstallationKeyTests: XCTestCase {
    func testSoftwareFallbackPersistsAndRotatesKey() async throws {
        let store = MemorySecureStore()
        let first = LatchwayInstallationKeyManager(
            softwareFallbackPolicy: .allowWhenSecureEnclaveUnavailable,
            store: store,
            preferSecureEnclave: false
        )
        let originalJWK = try await first.publicJWK()
        let originalStorage = await first.storage()
        XCTAssertEqual(originalStorage, .keychainSoftware)

        let restored = LatchwayInstallationKeyManager(
            softwareFallbackPolicy: .allowWhenSecureEnclaveUnavailable,
            store: store,
            preferSecureEnclave: false
        )
        let restoredJWK = try await restored.publicJWK()
        XCTAssertEqual(restoredJWK, originalJWK)

        try await restored.reset()
        let rotated = LatchwayInstallationKeyManager(
            softwareFallbackPolicy: .allowWhenSecureEnclaveUnavailable,
            store: store,
            preferSecureEnclave: false
        )
        let rotatedJWK = try await rotated.publicJWK()
        XCTAssertNotEqual(rotatedJWK, originalJWK)
    }

    func testDisallowedSoftwareFallbackFailsClosed() async {
        let manager = LatchwayInstallationKeyManager(
            softwareFallbackPolicy: .disallow,
            store: MemorySecureStore(),
            preferSecureEnclave: false
        )
        do {
            _ = try await manager.publicJWK()
            XCTFail("A disallowed software fallback must not create a key")
        } catch let error as LatchwayError {
            XCTAssertEqual(error, .secureEnclaveUnavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCorruptPersistedKeyIsReplacedWithoutExportingIt() async throws {
        let store = MemorySecureStore(values: [
            "installation-key": Data("not-a-private-key".utf8),
            "installation-key-kind": Data("keychain_software".utf8),
        ])
        let manager = LatchwayInstallationKeyManager(
            softwareFallbackPolicy: .allowWhenSecureEnclaveUnavailable,
            store: store,
            preferSecureEnclave: false
        )
        let jwk = try await manager.publicJWK()
        XCTAssertEqual(jwk.keyType, "EC")
        XCTAssertEqual(jwk.curve, "P-256")
        let persisted = try await store.read(account: "installation-key")
        XCTAssertEqual(persisted?.count, 32)
    }
}

private actor MemorySecureStore: LatchwaySecureDataStoring {
    private var values: [String: Data]
    init(values: [String: Data] = [:]) { self.values = values }
    func read(account: String) async throws -> Data? { values[account] }
    func write(_ data: Data, account: String) async throws { values[account] = data }
    func delete(account: String) async throws { values[account] = nil }
}
