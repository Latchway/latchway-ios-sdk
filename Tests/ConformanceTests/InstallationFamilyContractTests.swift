import Foundation
@testable import Latchway
import XCTest

final class InstallationFamilyContractTests: XCTestCase {
    func testCanonicalWireTwoFamilyVectorMatchesSwiftWireModels() throws {
        let root = try fixture()
        XCTAssertEqual(root["contract_version"] as? String, LatchwayVersion.contract)
        XCTAssertEqual(root["wire_protocol_version"] as? Int, LatchwayVersion.protocolVersion)

        let familyObject = try object(root, "family")
        let family = try decode(LatchwayInstallationFamilySummary.self, from: familyObject)
        XCTAssertEqual(family.status, "active")

        let rootComponentObject = try object(root, "root_component")
        let rootComponent = try decode(LatchwayClientComponentSummary.self, from: rootComponentObject)
        XCTAssertEqual(rootComponent.platform, "ios")
        XCTAssertEqual(rootComponent.kind, "main_app")
        XCTAssertTrue(rootComponent.isRoot)

        let rootClaims = try object(root, "root_session_claims")
        XCTAssertEqual(rootClaims["installation_family_id"] as? String, family.id)
        XCTAssertEqual(rootClaims["client_component_id"] as? String, rootComponent.id)
        XCTAssertEqual(rootClaims["component_definition_id"] as? String, rootComponent.definitionID)
        XCTAssertEqual(rootClaims["component_kind"] as? String, rootComponent.kind)
        XCTAssertEqual(rootClaims["component_is_root"] as? Bool, true)
        XCTAssertEqual(rootClaims["trust_source"] as? String, "direct_attested")

        let provisioned = try XCTUnwrap(root["provisioned_components"] as? [[String: Any]])
        XCTAssertEqual(provisioned.count, 2)
        var componentIDs = Set<String>()
        for vector in provisioned {
            let request = try object(vector, "request")
            let response = try object(vector, "response")
            let exchange = try object(vector, "session_exchange")
            let exchangeRequest = try object(exchange, "request")
            let exchangeResponse = try object(exchange, "response")
            let claims = try object(vector, "expected_session_claims")

            let publicJWK = try decode(LatchwayPublicJWK.self, from: object(request, "public_jwk"))
            let requestedFeatures = try XCTUnwrap(request["requested_features"] as? [String])
            let metadata = try object(request, "client_metadata")
            let encodedRequest = ComponentProvisioningRequest(
                componentDefinitionID: try string(request, "component_definition_id"),
                publicJWK: publicJWK,
                requestedFeatures: requestedFeatures,
                clientMetadata: .init(
                    appVersion: try string(metadata, "app_version"),
                    sdkVersion: try string(metadata, "sdk_version")
                )
            )
            XCTAssertEqual(
                try XCTUnwrap(jsonObject(JSONEncoder().encode(encodedRequest)) as? NSDictionary),
                request as NSDictionary
            )

            let provision = try decode(ComponentProvisioningWire.self, from: response)
            XCTAssertEqual(provision.installationFamilyID, family.id)
            XCTAssertTrue(componentIDs.insert(provision.componentID).inserted)
            XCTAssertEqual(provision.trust.source, .delegatedFromAttestedRoot)
            XCTAssertEqual(Set(provision.grantedFeatures).isSubset(of: Set(requestedFeatures)), true)
            XCTAssertEqual(try string(exchangeRequest, "component_id"), provision.componentID)
            XCTAssertEqual(try string(exchangeRequest, "refresh_grant"), provision.refreshGrant)

            let encodedExchange = ComponentSessionRequest(
                componentID: provision.componentID,
                refreshGrant: provision.refreshGrant
            )
            XCTAssertEqual(
                try XCTUnwrap(jsonObject(JSONEncoder().encode(encodedExchange)) as? NSDictionary),
                exchangeRequest as NSDictionary
            )

            let session = try decode(ComponentSessionGrantWire.self, from: exchangeResponse)
            XCTAssertTrue((60 ... 3_600).contains(session.expiresIn))
            XCTAssertNotNil(session.refreshExpiresAt)
            XCTAssertEqual(claims["installation_family_id"] as? String, family.id)
            XCTAssertEqual(claims["client_component_id"] as? String, provision.componentID)
            XCTAssertEqual(claims["component_definition_id"] as? String, request["component_definition_id"] as? String)
            XCTAssertEqual(claims["component_is_root"] as? Bool, false)
            XCTAssertEqual(claims["parent_component_id"] as? String, rootComponent.id)
            XCTAssertEqual(claims["trust_source"] as? String, "delegated_from_attested_root")
        }

        let revocations = try XCTUnwrap(root["revocations"] as? [[String: Any]])
        XCTAssertEqual(revocations.map { $0["scope"] as? String }, ["component", "family"])
        XCTAssertEqual(revocations[0]["expected_family_status"] as? String, "active")
        XCTAssertEqual(revocations[1]["expected_family_status"] as? String, "revoked")
    }

    private func fixture() throws -> [String: Any] {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "installation-family-v2",
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        )
        return try XCTUnwrap(try jsonObject(Data(contentsOf: url)) as? [String: Any])
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type,
        from object: [String: Any]
    ) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: JSONSerialization.data(withJSONObject: object))
    }

    private func jsonObject(_ data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data)
    }

    private func object(_ value: [String: Any], _ key: String) throws -> [String: Any] {
        try XCTUnwrap(value[key] as? [String: Any])
    }

    private func string(_ value: [String: Any], _ key: String) throws -> String {
        try XCTUnwrap(value[key] as? String)
    }
}
