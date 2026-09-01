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
        let bundle = try XCTUnwrap(root["bundle"] as? [String: Any])
        let requiredEntries = try XCTUnwrap(bundle["required_entries"] as? [String])
        let componentBinding = try XCTUnwrap(
            root["component_attestation_binding"] as? [String: Any]
        )

        XCTAssertEqual(root["contract_version"] as? String, LatchwayVersion.contract)
        XCTAssertEqual(root["contract_status"] as? String, "released")
        XCTAssertEqual(root["released_at"] as? String, "2026-09-01T20:25:00Z")
        XCTAssertEqual(wire["current"] as? Int, LatchwayVersion.protocolVersion)
        XCTAssertEqual(wire["supported"] as? [Int], LatchwayVersion.supportedProtocolVersions)
        XCTAssertEqual(wire["minimum"] as? Int, LatchwayVersion.minimumProtocolVersion)
        XCTAssertTrue(requiredEntries.contains("component-attestation-binding.schema.json"))
        XCTAssertEqual(componentBinding["version"] as? Int, 2)
        XCTAssertEqual(
            componentBinding["purpose"] as? String,
            "component_attestation_step_up"
        )
        XCTAssertEqual(componentBinding["canonicalization"] as? String, "RFC 8785 JCS")
        XCTAssertEqual(componentBinding["hash"] as? String, "SHA-256")
    }
}
