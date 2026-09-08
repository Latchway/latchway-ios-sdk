import CryptoKit
import Foundation
import XCTest

final class SharedNativeDraftTests: XCTestCase {
    func testCoreOwnedSharedNativeBytesArePinnedToReleasedContract() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let lock = try JSONDecoder().decode(Lock.self,
            from: Data(contentsOf: root.appendingPathComponent("contract.shared-native.lock.json")))
        XCTAssertEqual(lock.status, "released")
        XCTAssertEqual(lock.core_release, "v1.1.0")
        XCTAssertEqual(lock.contract_version, "1.1.0")
        XCTAssertEqual(lock.wire_protocol, 3)
        XCTAssertEqual(lock.files.count, 5)
        for (path, hash) in lock.files {
            let data = try Data(contentsOf: root.appendingPathComponent(path))
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(actual, hash, path)
        }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "shared-native-v3", withExtension: "json",
            subdirectory: "Fixtures/shared-native"))
        let vectors = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(vectors["shared_sdk"] as? String, "native")
        XCTAssertEqual(vectors["caller_header"] as? String, "X-Latchway-Caller")
    }

    private struct Lock: Decodable {
        let status: String
        let core_release: String?
        let contract_version: String
        let wire_protocol: Int
        let files: [String: String]
    }
}
