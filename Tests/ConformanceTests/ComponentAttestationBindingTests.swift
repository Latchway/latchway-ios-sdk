import CryptoKit
import Foundation
import Latchway
import XCTest

final class ComponentAttestationBindingTests: XCTestCase {
    func testEveryCanonicalComponentBindingVector() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "component-attestation-binding-v2",
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        )
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        XCTAssertEqual(root["format_version"] as? Int, 1)
        XCTAssertEqual(root["contract_version"] as? String, LatchwayVersion.contract)
        XCTAssertEqual(root["binding_version"] as? Int, 2)
        XCTAssertEqual(root["canonicalization"] as? String, "RFC 8785 JCS")
        XCTAssertEqual(root["hash"] as? String, "SHA-256")

        let vectors = try XCTUnwrap(root["vectors"] as? [[String: Any]])
        XCTAssertFalse(vectors.isEmpty)
        for vector in vectors {
            let id = try XCTUnwrap(vector["id"] as? String)
            let input = try XCTUnwrap(vector["input"] as? [String: Any])
            let canonical = try XCTUnwrap(vector["canonical_json"] as? String)
            let canonicalData = Data(canonical.utf8)
            let canonicalizedInput = try JSONSerialization.data(
                withJSONObject: input,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )

            XCTAssertEqual(canonicalizedInput, canonicalData, id)
            XCTAssertEqual(hex(canonicalData), vector["utf8_hex"] as? String, id)

            let digest = Data(SHA256.hash(data: canonicalData))
            XCTAssertEqual(hex(digest), vector["sha256_hex"] as? String, id)
            XCTAssertEqual(base64URL(digest), vector["sha256_base64url"] as? String, id)
        }
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
