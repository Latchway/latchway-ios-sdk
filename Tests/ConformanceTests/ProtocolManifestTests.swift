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
        XCTAssertEqual(wire["current"] as? Int, LatchwayVersion.protocolVersion)
        XCTAssertEqual(wire["supported"] as? [Int], [LatchwayVersion.protocolVersion])
        XCTAssertEqual(wire["minimum"] as? Int, LatchwayVersion.protocolVersion)
    }
}
