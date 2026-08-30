import Foundation
@testable import Latchway
import XCTest

final class ComponentRequestSecurityTests: XCTestCase {
    private let configuration = LatchwayConfiguration(
        baseURL: URL(string: "https://gateway.example.test/base")!,
        applicationID: "app_01J00000000000000000000000",
        environment: "production",
        rootKeychainAccessGroup: "ABCDE12345.com.example.latchway"
    )

    func testFeatureScopedOpaqueRoutesAcceptOnlyContractMethodsAndSafeRelativePaths() throws {
        for method in ["GET", "POST", "PUT", "PATCH", "DELETE"] {
            var request = URLRequest(
                url: URL(
                    string: "https://gateway.example.test/base/proxy/habit-assistant/vendor%20v1/models"
                )!
            )
            request.httpMethod = method

            XCTAssertNoThrow(try prepare(&request), method)
        }
    }

    func testOpaqueRouteRejectsFeatureConfusionAndDestinationAliases() throws {
        let longSuffix = String(repeating: "a", count: 2_049)
        let rejected: [(method: String, url: String)] = [
            ("GET", "https://gateway.example.test/base/proxy/other/vendor/models"),
            ("GET", "https://gateway.example.test/base/proxy/habit-assistant/"),
            ("GET", "https://gateway.example.test/base/proxy/habit-assistant/vendor/models?region=us"),
            ("GET", "https://gateway.example.test/base/proxy/habit-assistant/vendor//models"),
            ("GET", "https://gateway.example.test/base/proxy/habit-assistant/vendor/models/"),
            ("GET", "https://gateway.example.test/base/proxy/habit-assistant/vendor/%2Fmodels"),
            ("GET", "https://gateway.example.test/base/proxy/habit-assistant/vendor/%5Cmodels"),
            ("GET", "https://gateway.example.test/base/proxy/habit-assistant/vendor/%2emodels"),
            ("GET", "https://gateway.example.test/base/proxy/habit-assistant/http:attacker.invalid"),
            ("GET", "https://gateway.example.test/proxy/habit-assistant/vendor/models"),
            ("GET", "https://attacker.example/base/proxy/habit-assistant/vendor/models"),
            ("GET", "https://gateway.example.test/base/proxy/habit-assistant/vendor/models#fragment"),
            ("GET", "https://gateway.example.test/base/proxy/habit-assistant/\(longSuffix)"),
            ("HEAD", "https://gateway.example.test/base/proxy/habit-assistant/vendor/models"),
            ("OPTIONS", "https://gateway.example.test/base/proxy/habit-assistant/vendor/models"),
        ]

        for testCase in rejected {
            var request = URLRequest(url: try XCTUnwrap(URL(string: testCase.url)))
            request.httpMethod = testCase.method

            XCTAssertThrowsError(try prepare(&request), "\(testCase.method) \(testCase.url)") { error in
                guard case LatchwayError.invalidRequest = error else {
                    XCTFail("Expected invalidRequest, got \(error)")
                    return
                }
            }
        }
    }

    func testStructuredRoutesAreExactPostOnlyAndAllowOrdinaryQuery() throws {
        for path in [
            "v1/responses",
            "v1/chat/completions",
            "v1/embeddings",
            "v1/messages",
        ] {
            var request = URLRequest(
                url: URL(string: "https://gateway.example.test/base/\(path)?cursor=next")!
            )
            request.httpMethod = "POST"

            XCTAssertNoThrow(try prepare(&request), path)
        }
    }

    func testStructuredRoutesRejectOtherMethodsAndNearMissPaths() throws {
        let rejected: [(method: String, path: String)] = [
            ("GET", "v1/responses"),
            ("PUT", "v1/chat/completions"),
            ("PATCH", "v1/embeddings"),
            ("DELETE", "v1/messages"),
            ("POST", "v1"),
            ("POST", "v1/admin"),
            ("POST", "v1/responses/extra"),
            ("POST", "v1/Responses"),
            ("POST", "v1//responses"),
        ]

        for testCase in rejected {
            var request = URLRequest(
                url: URL(string: "https://gateway.example.test/base/\(testCase.path)")!
            )
            request.httpMethod = testCase.method

            XCTAssertThrowsError(try prepare(&request), "\(testCase.method) \(testCase.path)") { error in
                guard case LatchwayError.invalidRequest = error else {
                    XCTFail("Expected invalidRequest, got \(error)")
                    return
                }
            }
        }
    }

    private func prepare(_ request: inout URLRequest) throws {
        try LatchwayComponentRequestSecurity.prepare(
            &request,
            configuration: configuration,
            feature: "habit-assistant",
            framework: nil,
            allowManagedPlaceholder: false
        )
    }
}
