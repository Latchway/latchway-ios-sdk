import CryptoKit
import Foundation
import Latchway
import XCTest

final class DPoPContractVectorTests: XCTestCase {
    func testEveryContractVector() throws {
        let root = try fixture(named: "dpop-v1")
        XCTAssertEqual(root["contract_version"] as? String, LatchwayVersion.contract)
        XCTAssertEqual(root["wire_protocol_version"] as? Int, LatchwayVersion.protocolVersion)
        let accessToken = try string(root, "fixture_access_token")
        let expectedThumbprint = try string(root, "jwk_thumbprint_sha256_base64url")
        let referenceTime = try int(root, "reference_time")
        let maximumSkew = try int(root, "maximum_iat_skew_seconds")
        let vectors = try XCTUnwrap(root["vectors"] as? [[String: Any]])

        for vector in vectors {
            let id = try string(vector, "id")
            let expected = try XCTUnwrap(vector["expected"] as? [String: Any])
            let shouldBeValid = try XCTUnwrap(expected["valid"] as? Bool)
            let result = validate(
                proof: try string(vector, "proof"),
                request: try XCTUnwrap(vector["request"] as? [String: Any]),
                accessToken: accessToken,
                expectedThumbprint: expectedThumbprint,
                referenceTime: referenceTime,
                maximumSkew: maximumSkew
            )
            XCTAssertEqual(result == nil, shouldBeValid, "Contract vector \(id): \(result ?? "valid")")
            if let expectedCode = expected["error_code"] as? String {
                XCTAssertEqual(result, expectedCode, id)
            }
        }
    }

    private func validate(
        proof: String,
        request: [String: Any],
        accessToken: String,
        expectedThumbprint: String,
        referenceTime: Int,
        maximumSkew: Int
    ) -> String? {
        do {
            let segments = proof.split(separator: ".", omittingEmptySubsequences: false)
            guard segments.count == 3 else { return "dpop_invalid" }
            let headerData = try decodeBase64URL(String(segments[0]))
            let claimsData = try decodeBase64URL(String(segments[1]))
            let signatureData = try decodeBase64URL(String(segments[2]))
            guard let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
                  let claims = try JSONSerialization.jsonObject(with: claimsData) as? [String: Any],
                  header["typ"] as? String == "dpop+jwt",
                  header["alg"] as? String == "ES256",
                  let jwk = header["jwk"] as? [String: Any]
            else { return "dpop_invalid" }
            let forbidden = ["d", "p", "q", "dp", "dq", "qi", "oth", "k"]
            if forbidden.contains(where: { jwk[$0] != nil }) { return "dpop_invalid" }
            guard jwk["kty"] as? String == "EC", jwk["crv"] as? String == "P-256",
                  let x = jwk["x"] as? String, let y = jwk["y"] as? String
            else { return "dpop_invalid" }
            let xData = try decodeBase64URL(x)
            let yData = try decodeBase64URL(y)
            guard xData.count == 32, yData.count == 32, signatureData.count == 64 else { return "dpop_invalid" }
            let publicKey = try P256.Signing.PublicKey(x963Representation: Data([0x04]) + xData + yData)
            let signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureData)
            let signingInput = Data("\(segments[0]).\(segments[1])".utf8)
            guard publicKey.isValidSignature(signature, for: SHA256.hash(data: signingInput)) else { return "dpop_invalid" }

            let canonicalJWK = "{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"\(x)\",\"y\":\"\(y)\"}"
            guard base64URL(Data(SHA256.hash(data: Data(canonicalJWK.utf8)))) == expectedThumbprint else { return "dpop_invalid" }
            guard claims["htm"] as? String == request["method"] as? String,
                  let proofHTU = claims["htu"] as? String,
                  let requestURI = request["uri"] as? String,
                  let proofURL = URL(string: proofHTU),
                  let expectedURL = URL(string: requestURI),
                  try LatchwayDPoPProofFactory.normalizedHTU(proofURL) == LatchwayDPoPProofFactory.normalizedHTU(expectedURL),
                  let issuedAt = claims["iat"] as? Int,
                  abs(referenceTime - issuedAt) <= maximumSkew,
                  let jti = claims["jti"] as? String,
                  !jti.isEmpty,
                  jti.utf8.count <= 128
            else { return "dpop_invalid" }

            if request["use_fixture_access_token"] as? Bool == true {
                let expectedATH = base64URL(Data(SHA256.hash(data: Data(accessToken.utf8))))
                guard claims["ath"] as? String == expectedATH else { return "dpop_invalid" }
            } else if claims["ath"] != nil {
                return "dpop_invalid"
            }
            if let nonce = request["required_nonce"] as? String, claims["nonce"] as? String != nonce {
                return "dpop_nonce_required"
            }
            if request["proof_jti_already_seen"] as? Bool == true { return "dpop_replayed" }
            return nil
        } catch {
            return "dpop_invalid"
        }
    }

    private func fixture(named name: String) throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func string(_ object: [String: Any], _ key: String) throws -> String { try XCTUnwrap(object[key] as? String) }
    private func int(_ object: [String: Any], _ key: String) throws -> Int { try XCTUnwrap(object[key] as? Int) }

    private func decodeBase64URL(_ value: String) throws -> Data {
        guard !value.contains("=") else { throw LatchwayError.invalidServerResponse }
        var value = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        return try XCTUnwrap(Data(base64Encoded: value))
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
