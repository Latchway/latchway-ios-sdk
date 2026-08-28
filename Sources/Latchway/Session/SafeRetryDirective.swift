import Foundation

enum SafeRetryDirective: Sendable, Equatable {
    case sessionExpired
    case dpopNonceRequired(String)

    private static let requiredProblemMembers: Set<String> = [
        "type", "title", "status", "detail", "code", "request_id", "retryable",
    ]

    private struct Problem: Decodable {
        let type: String
        let title: String
        let status: Int
        let detail: String
        let code: String
        let requestID: String
        let retryable: Bool

        enum CodingKeys: String, CodingKey {
            case type, title, status, detail, code, retryable
            case requestID = "request_id"
        }
    }

    static func parse(
        response: LatchwayHTTPResponse,
        expectedRequestID: String?
    ) -> Self? {
        guard response.statusCode == 401,
              response.body.count <= 65_536,
              mediaType(uniqueHeader("Content-Type", in: response)) == "application/problem+json",
              let expectedRequestID,
              isValidRequestID(expectedRequestID),
              uniqueHeader("X-Latchway-Request-ID", in: response) == expectedRequestID
        else { return nil }

        do { try StrictJSON.validate(response.body) }
        catch { return nil }

        guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              Set(object.keys) == requiredProblemMembers,
              let problem = try? JSONDecoder().decode(Problem.self, from: response.body),
              problem.status == 401,
              problem.requestID == expectedRequestID,
              problem.retryable
        else { return nil }

        switch problem.code {
        case "session_expired":
            guard problem.type == "https://latchway.dev/problems/session_expired",
                  problem.title == "Session expired",
                  problem.detail == "The Latchway session is expired.",
                  matchingHeaders("DPoP-Nonce", in: response).isEmpty
            else { return nil }
            return .sessionExpired
        case "dpop_nonce_required":
            guard problem.type == "https://latchway.dev/problems/dpop_nonce_required",
                  problem.title == "DPoP nonce required",
                  problem.detail == "A fresh server DPoP nonce is required.",
                  let nonce = uniqueHeader("DPoP-Nonce", in: response),
                  isValidNonce(nonce)
            else { return nil }
            return .dpopNonceRequired(nonce)
        default:
            return nil
        }
    }

    static func isValidNonce(_ nonce: String) -> Bool {
        let bytes = Array(nonce.utf8)
        return (16 ... 512).contains(bytes.count)
            && bytes.allSatisfy { byte in
                // A nonce response must be one unambiguous printable ASCII
                // field value. Commas can be introduced by duplicate-header
                // joining, and whitespace makes proxy normalization ambiguous.
                (0x21 ... 0x7E).contains(byte) && byte != 0x2C
            }
    }

    private static func uniqueHeader(
        _ name: String,
        in response: LatchwayHTTPResponse
    ) -> String? {
        let values = matchingHeaders(name, in: response)
        guard values.count == 1 else { return nil }
        return values[0]
    }

    private static func matchingHeaders(
        _ name: String,
        in response: LatchwayHTTPResponse
    ) -> [String] {
        response.headers.compactMap { key, value in
            key.caseInsensitiveCompare(name) == .orderedSame ? value : nil
        }
    }

    private static func isValidRequestID(_ value: String) -> Bool {
        (8 ... 128).contains(value.utf8.count)
            && value.range(
                of: "^[A-Za-z0-9][A-Za-z0-9._:-]*$",
                options: .regularExpression
            ) != nil
    }

    private static func mediaType(_ value: String?) -> String? {
        value?
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
