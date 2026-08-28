import CryptoKit
import Foundation
import Latchway
import XCTest

final class AttestationBindingTests: XCTestCase {
    func testEveryCanonicalBindingVector() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "attestation-binding-v1", withExtension: "json", subdirectory: "Fixtures"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(root["contract_version"] as? String, LatchwayVersion.contract)
        XCTAssertEqual(root["canonicalization"] as? String, "RFC 8785 JCS")
        XCTAssertEqual(root["hash"] as? String, "SHA-256")
        let vectors = try XCTUnwrap(root["vectors"] as? [[String: Any]])
        for vector in vectors {
            let id = try XCTUnwrap(vector["id"] as? String)
            let canonical = try XCTUnwrap(vector["canonical_json"] as? String)
            let canonicalData = Data(canonical.utf8)
            XCTAssertEqual(canonicalData.map { String(format: "%02x", $0) }.joined(), vector["utf8_hex"] as? String, id)
            let digest = Data(SHA256.hash(data: canonicalData))
            XCTAssertEqual(digest.map { String(format: "%02x", $0) }.joined(), vector["sha256_hex"] as? String, id)
            XCTAssertEqual(base64URL(digest), vector["sha256_base64url"] as? String, id)

            let parsed = try JSONSerialization.jsonObject(with: canonicalData)
            let regenerated = try JSONSerialization.data(withJSONObject: parsed, options: [.sortedKeys, .withoutEscapingSlashes])
            XCTAssertEqual(regenerated, canonicalData, id)
        }
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
