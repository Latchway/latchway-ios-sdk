import Foundation
@testable import Latchway
import XCTest

final class ProblemWireTests: XCTestCase {
    private let operationID = "arq_0123456789ABCDEFGHJKMNPQRS"

    func testOperationIndeterminateMapsCanonicalOperationIDToPublicProblem() throws {
        var document = problemDocument(
            code: "operation_indeterminate",
            status: 503,
            retryable: true
        )
        document["operation_id"] = operationID

        let wire = try decode(document)

        XCTAssertTrue(wire.isValid)
        XCTAssertEqual(wire.problem.code, .operationIndeterminate)
        XCTAssertEqual(wire.problem.operationID, operationID)
        XCTAssertEqual(LatchwayErrorCode(rawValue: "operation_indeterminate"), .operationIndeterminate)
        XCTAssertEqual(LatchwayErrorCode.operationIndeterminate.description, "operation_indeterminate")
    }

    func testOperationIndeterminateRequiresCanonicalIDAndRegistrySemantics() throws {
        let invalidDocuments: [[String: Any]] = [
            problemDocument(code: "operation_indeterminate", status: 503, retryable: true),
            problemDocument(
                code: "operation_indeterminate",
                status: 503,
                retryable: true,
                operationID: "arq_invalid"
            ),
            problemDocument(
                code: "operation_indeterminate",
                status: 500,
                retryable: true,
                operationID: operationID
            ),
            problemDocument(
                code: "operation_indeterminate",
                status: 503,
                retryable: false,
                operationID: operationID
            ),
        ]

        for document in invalidDocuments {
            XCTAssertFalse(try decode(document).isValid)
        }
    }

    func testOtherProblemsForbidOperationIDMember() throws {
        for value: Any in [operationID, NSNull()] {
            var document = problemDocument(code: "internal_error", status: 500, retryable: false)
            document["operation_id"] = value
            XCTAssertFalse((try? decode(document).isValid) ?? false)
        }
    }

    func testProblemRequiresMatchingCanonicalDocumentationURLs() throws {
        let canonical = problemDocument(code: "future_safe_code", status: 418, retryable: false)
        XCTAssertTrue(try decode(canonical).isValid)
        XCTAssertEqual(
            try decode(canonical).problem.documentationURL.absoluteString,
            "https://docs.latchway.dev/errors/future-safe-code"
        )

        for key in ["type", "documentation_url"] {
            var mismatch = canonical
            mismatch[key] = "https://malicious.invalid/future-safe-code"
            XCTAssertFalse(try decode(mismatch).isValid)
        }

        var missing = canonical
        missing.removeValue(forKey: "documentation_url")
        XCTAssertThrowsError(try decode(missing))
    }

    func testPublicDecoderPreservesExistingDiagnosticsAndIgnoresFutureMembers() throws {
        var document = problemDocument(code: "quota_exceeded", status: 429, retryable: true)
        document["retry_after"] = "2026-09-11T10:20:30.125Z"
        document["feature"] = "habi-assistant"
        document["errors"] = [["path": "tools[0].function.parameters", "message": "Function tool parameters must be an object."]]
        document["supported_protocol_versions"] = [1, 2, 3]
        document["instance"] = "/requests/request-12345678"
        document["future_optional_extension"] = ["secret": "not-copied-to-diagnostics"]
        let response = try response(document)
        let problem = try LatchwayProblem.decode(from: response)
        XCTAssertEqual(problem.detail, document["detail"] as? String)
        XCTAssertEqual(problem.feature, "habi-assistant")
        XCTAssertEqual(problem.errors, [.init(path: "tools[0].function.parameters", message: "Function tool parameters must be an object.")])
        XCTAssertEqual(problem.supportedProtocolVersions, [1, 2, 3])
        XCTAssertEqual(problem.instance, "/requests/request-12345678")
        XCTAssertNotNil(problem.retryAfter)
        XCTAssertEqual(LatchwayClient.problem(from: response), problem)
        XCTAssertFalse(LatchwayError.server(problem).description.contains("not-copied"))
    }

    func testPublicDecoderRejectsInvalidOptionalFieldsAndPreservesHeaderCorrelation() throws {
        let invalid: [(String, Any)] = [
            ("feature", "../invalid"), ("errors", [["path": "body"]]),
            ("errors", [["path": String(repeating: "x", count: 513), "message": "invalid"]]),
            ("errors", Array(repeating: ["path": "body", "message": "invalid"], count: 101)),
            ("supported_protocol_versions", [1, 1]), ("supported_protocol_versions", [0]),
            ("supported_protocol_versions", [true]), ("retry_after", "not-a-date"),
            ("instance", "\nunsafe"),
        ]
        for (key, value) in invalid {
            var document = problemDocument(code: "request_invalid", status: 400, retryable: false)
            document[key] = value
            XCTAssertThrowsError(try LatchwayProblem.decode(from: response(document))) { error in
                XCTAssertEqual(error as? LatchwayHTTPResponseError, .init(statusCode: 400, requestID: "request-12345678"), key)
            }
        }
    }

    func testPublicDecoderBoundsBodiesAndRejectsMismatchedIdentityWithoutExposingBody() throws {
        let document = problemDocument(code: "request_invalid", status: 400, retryable: false)
        let valid = try response(document)
        let samples = [
            LatchwayHTTPResponse(statusCode: 400, headers: valid.headers, body: Data(repeating: 32, count: 65_537)),
            LatchwayHTTPResponse(statusCode: 400, headers: valid.headers, body: Data("private upstream error".utf8)),
            LatchwayHTTPResponse(statusCode: 403, headers: valid.headers, body: valid.body),
            LatchwayHTTPResponse(statusCode: 400, headers: ["Content-Type": "text/html", "X-Latchway-Request-ID": "request-12345678"], body: valid.body),
            LatchwayHTTPResponse(statusCode: 400, headers: ["Content-Type": "application/problem+json", "X-Latchway-Request-ID": "request-other-id"], body: valid.body),
        ]
        for sample in samples {
            XCTAssertThrowsError(try LatchwayProblem.decode(from: sample)) { error in
                guard let error = error as? LatchwayHTTPResponseError else {
                    return XCTFail("Expected correlated HTTP failure")
                }
                XCTAssertEqual(error.statusCode, sample.statusCode)
                XCTAssertEqual(error.requestID, sample.header("X-Latchway-Request-ID"))
                XCTAssertFalse(String(describing: error).contains("private upstream"))
            }
        }
    }

    private func response(_ document: [String: Any]) throws -> LatchwayHTTPResponse {
        .init(statusCode: document["status"] as! Int,
              headers: ["Content-Type": "application/problem+json", "X-Latchway-Request-ID": "request-12345678"],
              body: try JSONSerialization.data(withJSONObject: document))
    }

    func testKnownOptionalNullsAreRejectedAndSafeCorrelationMatchesOtherSDKs() throws {
        for key in ["retry_after", "operation_id", "feature", "errors", "supported_protocol_versions", "instance"] {
            var document = problemDocument(code: "request_invalid", status: 400, retryable: false)
            document[key] = NSNull()
            XCTAssertThrowsError(try LatchwayProblem.decode(from: response(document)), key)
        }
        for value in ["request.with.dots", "trace:request-123", "Request_ID-123456"] {
            XCTAssertEqual(LatchwayHTTPResponseError(statusCode: 500, requestID: value).requestID, value)
        }
        for value in ["-request-123", "request id", "request\n123", "short"] {
            XCTAssertNil(LatchwayHTTPResponseError(statusCode: 500, requestID: value).requestID)
        }
    }

    private func problemDocument(
        code: String,
        status: Int,
        retryable: Bool,
        operationID: String? = nil
    ) -> [String: Any] {
        var document: [String: Any] = [
            "type": "https://docs.latchway.dev/errors/\(code.replacingOccurrences(of: "_", with: "-"))",
            "documentation_url": "https://docs.latchway.dev/errors/\(code.replacingOccurrences(of: "_", with: "-"))",
            "title": "Safe failure",
            "status": status,
            "detail": "The request was rejected safely.",
            "code": code,
            "request_id": "request-12345678",
            "retryable": retryable,
        ]
        document["operation_id"] = operationID
        return document
    }

    private func decode(_ document: [String: Any]) throws -> ProblemWire {
        let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        try StrictJSON.validate(data)
        return try JSONDecoder().decode(ProblemWire.self, from: data)
    }
}
