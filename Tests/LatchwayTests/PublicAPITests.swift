import Foundation
import Security
@testable import Latchway
import XCTest

final class PublicAPITests: XCTestCase {
    func testRequestedConfigurationInitializerRemainsAvailable() {
        let configuration = LatchwayConfiguration(
            baseURL: URL(string: "https://gateway.example.test")!,
            applicationID: "app_01J00000000000000000000000",
            environment: "production",
            rootKeychainAccessGroup: "ABCDE12345.com.example.latchway"
        )
        XCTAssertEqual(configuration.baseURL.absoluteString, "https://gateway.example.test")
        XCTAssertEqual(configuration.applicationID, "app_01J00000000000000000000000")
        XCTAssertEqual(configuration.environment, "production")
        XCTAssertEqual(configuration.rootKeychainAccessGroup, "ABCDE12345.com.example.latchway")
        XCTAssertEqual(configuration.clientRuntime, .iOS)
        XCTAssertEqual(configuration.clientSDKVersion, LatchwayVersion.sdk)
        XCTAssertEqual(configuration.softwareKeyFallbackPolicy, .disallow)
    }

    func testServerErrorDescriptionRedactsDetail() {
        let secret = "secret-access-token-never-print"
        let problem = LatchwayProblem(
            code: .sessionExpired,
            title: "Expired",
            detail: secret,
            status: 401,
            requestID: "request-12345678",
            retryable: true
        )
        let description = LatchwayError.server(problem).description
        XCTAssertFalse(description.contains(secret))
        XCTAssertTrue(description.contains("session_expired"))
        XCTAssertTrue(description.contains("request-12345678"))
        XCTAssertEqual(
            problem.documentationURL.absoluteString,
            "https://docs.latchway.dev/errors/session-expired"
        )
    }

    func testErrorDocumentationURLUsesOneEscapedStablePathSegment() {
        XCTAssertEqual(
            LatchwayErrorCode.quotaExceeded.documentationURL.absoluteString,
            "https://docs.latchway.dev/errors/quota-exceeded"
        )
        XCTAssertEqual(
            LatchwayErrorCode(rawValue: "future/code?fragment#value").documentationURL.absoluteString,
            "https://docs.latchway.dev/errors/future%2Fcode%3Ffragment%23value"
        )
        XCTAssertEqual(
            LatchwayError.invalidServerResponse.documentationURL.absoluteString,
            "https://docs.latchway.dev/errors/server-response-invalid"
        )
        XCTAssertEqual(LatchwayError.invalidServerResponse.code, "server_response_invalid")
    }

    func testCurrentAppOptionsRequireNoMigrationInventory() throws {
        let identity = try LatchwaySuppliedIdentityConfiguration.firebaseProject(projectID: "test-project")
        let options = LatchwayAppOptions(
            baseURL: URL(string: "https://gateway.example.test")!,
            applicationID: "app", environment: "production", rootKeychainAccessGroup: "TEAM.app",
            suppliedIdentity: identity)
        XCTAssertEqual(options.suppliedIdentity, identity)
        XCTAssertEqual(LatchwayVersion.protocolVersion, 2)
        XCTAssertEqual(LatchwayVersion.supportedProtocolVersions, [1, 2, 3])
    }

    func testIndeterminateOperationPreservesActionableIDWhileDescriptionRedactsDetail() {
        let secret = "provider-secret-never-print"
        let operationID = "arq_0123456789ABCDEFGHJKMNPQRS"
        let problem = LatchwayProblem(
            code: .operationIndeterminate,
            title: "Operation outcome indeterminate",
            detail: secret,
            status: 503,
            requestID: "request-12345678",
            retryable: true,
            operationID: operationID
        )

        XCTAssertEqual(problem.operationID, operationID)
        XCTAssertFalse(LatchwayError.server(problem).description.contains(secret))
    }

    func testJSONValueRoundTrip() throws {
        let value = LatchwayJSONValue.object([
            "safe": .string("value"),
            "count": .number(2),
            "items": .array([.bool(true), .null]),
        ])
        XCTAssertEqual(try JSONDecoder().decode(LatchwayJSONValue.self, from: JSONEncoder().encode(value)), value)
    }

    func testCurrentAccountScopeIsSharedAcrossCallersAndIsolatedAcrossGenerations() {
        let first = UUID(), second = UUID()
        let native = LatchwayProcessScopeIdentity.sharedRoot(scope: "same-account", generation: first)
        let reactNative = LatchwayProcessScopeIdentity.sharedRoot(scope: "same-account", generation: first)
        XCTAssertEqual(native, reactNative)
        XCTAssertNotEqual(native, LatchwayProcessScopeIdentity.sharedRoot(scope: "same-account", generation: second))
        XCTAssertNotEqual(native, LatchwayProcessScopeIdentity.sharedRoot(scope: "other-account", generation: first))
    }

    func testRootKeychainIdentityAlwaysCarriesExplicitAccessGroup() {
        let group = "ABCDE12345.com.example.latchway"
        let query = LatchwayKeychainQuery.identity(
            service: "dev.latchway.sdk.test",
            account: "session",
            accessGroup: group,
            synchronizable: kCFBooleanFalse as Any
        )
        XCTAssertEqual(query[kSecAttrAccessGroup] as? String, group)
    }
}
