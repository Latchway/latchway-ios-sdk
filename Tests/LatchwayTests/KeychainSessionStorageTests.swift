import Foundation
@testable import Latchway
import XCTest

final class KeychainSessionStorageTests: XCTestCase {
    func testPreflightIsCachedBeforeSessionStorageAccess() async throws {
        let counter = SessionPreflightCounter()
        let store = SessionCountingStore()
        let storage = LatchwayKeychainSessionStorage(
            store: store,
            rootKeychainPreflight: { counter.increment() }
        )

        let first = try await storage.load()
        let second = try await storage.load()
        let readCount = await store.readCount()
        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(readCount, 2)
    }

    func testPreflightFailureDoesNotReadOrMutateSessionStorage() async {
        let store = SessionCountingStore()
        let storage = LatchwayKeychainSessionStorage(
            store: store,
            rootKeychainPreflight: { throw LatchwayError.rootKeychainMigrationRequired }
        )

        do {
            _ = try await storage.load()
            XCTFail("Expected migration failure")
        } catch let error as LatchwayError {
            XCTAssertEqual(error, .rootKeychainMigrationRequired)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let operationCount = await store.operationCount()
        XCTAssertEqual(operationCount, 0)
    }
}

private actor SessionCountingStore: LatchwaySecureDataStoring {
    private var reads = 0
    private var writes = 0
    private var deletes = 0
    func read(account: String) async throws -> Data? { reads += 1; return nil }
    func write(_ data: Data, account: String) async throws { writes += 1 }
    func delete(account: String) async throws { deletes += 1 }
    func readCount() -> Int { reads }
    func operationCount() -> Int { reads + writes + deletes }
}

private final class SessionPreflightCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
