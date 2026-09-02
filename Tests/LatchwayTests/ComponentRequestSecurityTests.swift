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

    func testReactNativeFrameworkMetadataUsesCanonicalHeaderPair() throws {
        var request = URLRequest(
            url: URL(string: "https://gateway.example.test/base/v1/responses")!
        )
        request.httpMethod = "POST"
        let framework = LatchwayFrameworkMetadata.reactNativeFetch(version: "0.82.0")

        try LatchwayComponentRequestSecurity.prepare(
            &request,
            configuration: configuration,
            feature: "habit-assistant",
            framework: framework,
            allowManagedPlaceholder: true
        )
        LatchwayComponentRequestSecurity.addMetadata(
            to: &request,
            configuration: configuration,
            framework: framework
        )

        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Latchway-Framework"), "react-native-fetch")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Latchway-Framework-Version"), "0.82.0")
    }

    func testFoundationModelsFrameworkMetadataUsesCanonicalHeaderPair() throws {
        var request = URLRequest(
            url: URL(string: "https://gateway.example.test/base/v1/responses")!
        )
        request.httpMethod = "POST"
        let framework = LatchwayFrameworkMetadata.foundationModels(version: "27.0.0")

        try LatchwayComponentRequestSecurity.prepare(
            &request,
            configuration: configuration,
            feature: "habit-assistant",
            framework: framework,
            allowManagedPlaceholder: true
        )
        LatchwayComponentRequestSecurity.addMetadata(
            to: &request,
            configuration: configuration,
            framework: framework
        )

        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Latchway-Framework"), "foundation-models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Latchway-Framework-Version"), "27.0.0")
    }

    // FW-REQ-104
    func testFWREQ104AllowedCustomHeadersSurviveNativePreparation() throws {
        let frameworks: [(metadata: LatchwayFrameworkMetadata, expectedID: String)] = [
            (.swiftOpenAI(version: "4.6.0"), "swift-openai"),
            (.foundationModels(version: "27.0.0"), "foundation-models"),
        ]

        for testCase in frameworks {
            var request = URLRequest(
                url: URL(string: "https://gateway.example.test/base/v1/responses")!
            )
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("correlation-123", forHTTPHeaderField: "X-Application-Correlation-ID")
            request.setValue("request-custom-12345678", forHTTPHeaderField: "X-Latchway-Request-ID")

            try LatchwayComponentRequestSecurity.prepare(
                &request,
                configuration: configuration,
                feature: "habit-assistant",
                framework: testCase.metadata,
                allowManagedPlaceholder: true
            )
            LatchwayComponentRequestSecurity.addMetadata(
                to: &request,
                configuration: configuration,
                framework: testCase.metadata
            )

            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "X-Application-Correlation-ID"),
                "correlation-123"
            )
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "X-Latchway-Request-ID"),
                "request-custom-12345678"
            )
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "X-Latchway-Framework"),
                testCase.expectedID
            )
        }
    }

    // FW-REQ-106
    func testFWREQ106NativeURLRequestTimeoutSurvivesPreparationWhenExpressible() throws {
        var request = URLRequest(
            url: URL(string: "https://gateway.example.test/base/v1/responses")!
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 7.25

        try LatchwayComponentRequestSecurity.prepare(
            &request,
            configuration: configuration,
            feature: "habit-assistant",
            framework: nil,
            allowManagedPlaceholder: false
        )

        XCTAssertEqual(request.timeoutInterval, 7.25)
    }

    // FW-SEC-102
    func testFWSEC102SinglePlaceholderIsRemovedAndDuplicateAuthorizationIsRejected() throws {
        var single = URLRequest(
            url: URL(string: "https://gateway.example.test/base/v1/responses")!
        )
        single.httpMethod = "POST"
        single.setValue(
            "Bearer \(LatchwayFeatureTransport.placeholderAPIKey)",
            forHTTPHeaderField: "Authorization"
        )

        try LatchwayComponentRequestSecurity.prepare(
            &single,
            configuration: configuration,
            feature: "habit-assistant",
            framework: .swiftOpenAI(version: "4.6.0"),
            allowManagedPlaceholder: true
        )
        XCTAssertNil(single.value(forHTTPHeaderField: "Authorization"))

        var duplicate = URLRequest(
            url: URL(string: "https://gateway.example.test/base/v1/responses")!
        )
        duplicate.httpMethod = "POST"
        duplicate.setValue(
            "Bearer \(LatchwayFeatureTransport.placeholderAPIKey)",
            forHTTPHeaderField: "Authorization"
        )
        duplicate.addValue("Bearer attacker-supplied", forHTTPHeaderField: "Authorization")

        XCTAssertThrowsError(
            try LatchwayComponentRequestSecurity.prepare(
                &duplicate,
                configuration: configuration,
                feature: "habit-assistant",
                framework: .swiftOpenAI(version: "4.6.0"),
                allowManagedPlaceholder: true
            )
        ) { error in
            guard case LatchwayError.invalidRequest = error else {
                XCTFail("Expected invalidRequest, got \(error)")
                return
            }
        }
    }

    func testFWSEC102FoundationModelsDuplicateAuthorizationIsRejectedBeforeNativeDispatch() throws {
        var request = URLRequest(
            url: URL(string: "https://gateway.example.test/base/v1/responses")!
        )
        request.httpMethod = "POST"
        request.setValue("Bearer caller-one", forHTTPHeaderField: "Authorization")
        request.addValue("Bearer caller-two", forHTTPHeaderField: "Authorization")

        XCTAssertThrowsError(
            try LatchwayComponentRequestSecurity.prepare(
                &request,
                configuration: configuration,
                feature: "habit-assistant",
                framework: .foundationModels(version: "27.0.0"),
                allowManagedPlaceholder: false
            )
        ) { error in
            guard case LatchwayError.invalidRequest = error else {
                XCTFail("Expected invalidRequest, got \(error)")
                return
            }
        }
    }

    func testFWBEH107SharedNativeTransportHasNoLoggingCallSurface() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = packageRoot.appendingPathComponent("Sources/Latchway")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: nil
        ))
        let loggingCallPatterns = [
            #"(?<![A-Za-z0-9_])print\s*\("#,
            #"(?<![A-Za-z0-9_])debugPrint\s*\("#,
            #"(?<![A-Za-z0-9_])dump\s*\("#,
            #"(?<![A-Za-z0-9_])Logger\s*[\.(]"#,
            #"(?<![A-Za-z0-9_])os_log\s*\("#,
            #"(?<![A-Za-z0-9_])NSLog\s*\("#,
        ]
        var scanned = 0

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            scanned += 1
            for pattern in loggingCallPatterns {
                XCTAssertNil(
                    source.range(of: pattern, options: .regularExpression),
                    "\(fileURL.path): \(pattern)"
                )
            }
        }
        XCTAssertGreaterThan(scanned, 0)
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
