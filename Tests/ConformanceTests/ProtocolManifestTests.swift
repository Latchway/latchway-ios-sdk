import Foundation
import Latchway
import XCTest

final class ProtocolManifestTests: XCTestCase {
    func testNormativeProtocolManifestMatchesRuntimeContract() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "protocol-version",
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        )
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let wire = try XCTUnwrap(root["wire_protocol"] as? [String: Any])

        XCTAssertEqual(root["contract_version"] as? String, LatchwayVersion.contract)
        XCTAssertEqual(root["contract_status"] as? String, "draft")
        XCTAssertTrue(root.keys.contains("released_at"))
        XCTAssertTrue(root["released_at"] is NSNull)
        XCTAssertEqual(wire["current"] as? Int, LatchwayVersion.protocolVersion)
        XCTAssertEqual(wire["supported"] as? [Int], LatchwayVersion.supportedProtocolVersions)
        XCTAssertEqual(wire["minimum"] as? Int, LatchwayVersion.minimumProtocolVersion)
    }
}
