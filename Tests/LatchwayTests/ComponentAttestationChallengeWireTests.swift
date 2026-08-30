import Foundation
@testable import Latchway
import XCTest

final class ComponentAttestationChallengeWireTests: XCTestCase {
    func testAllowsOpenProviderOptions() throws {
        var document = validDocument()
        var attestation = try XCTUnwrap(document["attestation"] as? [String: Any])
        attestation["provider_options"] = [
            "future_boolean": true,
            "future_object": [
                "nested_array": ["value", 7, NSNull()],
            ],
        ]
        document["attestation"] = attestation

        let wire = try decode(document)

        XCTAssertEqual(wire.attestation.providerOptions?["future_boolean"], .bool(true))
        XCTAssertEqual(
            wire.attestation.providerOptions?["future_object"],
            .object(["nested_array": .array([.string("value"), .number(7), .null])])
        )
    }

    func testRejectsUnknownTopLevelKey() throws {
        var document = validDocument()
        document["future_top_level"] = true

        XCTAssertThrowsError(try decode(document))
    }

    func testRejectsUnknownAttestationKey() throws {
        var document = validDocument()
        var attestation = try XCTUnwrap(document["attestation"] as? [String: Any])
        attestation["future_attestation_member"] = true
        document["attestation"] = attestation

        XCTAssertThrowsError(try decode(document))
    }

    private func validDocument() -> [String: Any] {
        [
            "challenge_id": "chl_01J00000000000000000000003",
            "challenge_nonce": "IiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiI",
            "binding_version": 2,
            "issued_at": 1_787_820_003,
            "expires_at": "2026-08-27T09:25:03Z",
            "attestation": [
                "provider": "app_attest",
                "mode": "required",
                "client_data_hash": "Ux-vUsM3zk0eueEMcCyigrcT56BVboIAxENi1imcnBg",
                "provider_options": [
                    "bundle_id": "com.example.action",
                ],
            ],
        ]
    }

    private func decode(
        _ document: [String: Any]
    ) throws -> ComponentAttestationChallengeWire {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        return try decoder.decode(ComponentAttestationChallengeWire.self, from: data)
    }
}
