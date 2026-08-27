import CryptoKit
import Foundation
@testable import Latchway
import LatchwayTesting
import XCTest

final class DPoPTests: XCTestCase {
    func testRFC7638ThumbprintMatchesContractVector() async throws {
        let raw = try decodeBase64URL("2ZFd1bc5bCB8zu8OEf5l7O9x_SxbsQNQMNn0si4NxxI")
        let key = try LatchwayDeterministicInstallationKey(rawPrivateKey: raw)
        let factory = LatchwayDPoPProofFactory(key: key, clock: LatchwayTestClock(now: Date(timeIntervalSince1970: 1_700_000_000)))
        let thumbprint = try await factory.thumbprint()
        XCTAssertEqual(thumbprint, "bX0yCl562RPdpf8cJHVLBeUXu6PWExYJ0w-Bydre3q8")
    }

    func testGeneratedProofCarriesOnlyPublicJWKAndRequiredClaims() async throws {
        let raw = try decodeBase64URL("2ZFd1bc5bCB8zu8OEf5l7O9x_SxbsQNQMNn0si4NxxI")
        let key = try LatchwayDeterministicInstallationKey(rawPrivateKey: raw)
        let factory = LatchwayDPoPProofFactory(key: key, clock: LatchwayTestClock(now: Date(timeIntervalSince1970: 1_700_000_000)))
        let token = "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ0ZXN0In0.signature"
        let proof = try await factory.proof(
            method: "post",
            url: URL(string: "https://GATEWAY.example.test:443/a/../v1/responses?ignored=true#fragment")!,
            accessToken: token,
            nonce: "nonce-fixture-0123456789abcdef",
            proofID: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        )
        let segments = proof.split(separator: ".")
        XCTAssertEqual(segments.count, 3)
        let header = try XCTUnwrap(JSONSerialization.jsonObject(with: decodeBase64URL(String(segments[0]))) as? [String: Any])
        let claims = try XCTUnwrap(JSONSerialization.jsonObject(with: decodeBase64URL(String(segments[1]))) as? [String: Any])
        XCTAssertEqual(header["typ"] as? String, "dpop+jwt")
        XCTAssertEqual(header["alg"] as? String, "ES256")
        let jwk = try XCTUnwrap(header["jwk"] as? [String: Any])
        XCTAssertNil(jwk["d"])
        XCTAssertEqual(claims["htm"] as? String, "POST")
        XCTAssertEqual(claims["htu"] as? String, "https://gateway.example.test/v1/responses")
        XCTAssertEqual(claims["jti"] as? String, "00000000-0000-4000-8000-000000000002")
        XCTAssertEqual(claims["nonce"] as? String, "nonce-fixture-0123456789abcdef")
        XCTAssertNotNil(claims["ath"])

        let publicKey = try P256.Signing.PublicKey(x963Representation: Data([0x04]) + decodeBase64URL(jwk["x"] as! String) + decodeBase64URL(jwk["y"] as! String))
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: decodeBase64URL(String(segments[2])))
        XCTAssertTrue(publicKey.isValidSignature(signature, for: SHA256.hash(data: Data("\(segments[0]).\(segments[1])".utf8))))
    }

    func testHTUNormalizationMatchesServerProfile() throws {
        let cases: [(String, String)] = [
            ("https://EXAMPLE.com", "https://example.com/"),
            ("https://example.com:443/a/%7euser", "https://example.com/a/~user"),
            ("http://example.com:80/a//b", "http://example.com/a//b"),
            ("https://example.com/a/b/../c?x=1#f", "https://example.com/a/c"),
            ("https://[2001:db8::1]:8443/path", "https://[2001:db8::1]:8443/path"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(try LatchwayDPoPProofFactory.normalizedHTU(URL(string: input)!), expected, input)
        }
    }

    func testHTURejectsCredentialsAndNonHTTP() {
        XCTAssertThrowsError(try LatchwayDPoPProofFactory.normalizedHTU(URL(string: "https://user:pass@example.com/")!))
        XCTAssertThrowsError(try LatchwayDPoPProofFactory.normalizedHTU(URL(string: "file:///tmp/secret")!))
    }

    private func decodeBase64URL(_ value: String) throws -> Data {
        var value = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        return try XCTUnwrap(Data(base64Encoded: value))
    }
}
