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
            XCTAssertFalse(try decode(document).isValid)
        }
    }

    private func problemDocument(
        code: String,
        status: Int,
        retryable: Bool,
        operationID: String? = nil
    ) -> [String: Any] {
        var document: [String: Any] = [
            "type": "https://latchway.dev/problems/\(code)",
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
