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
        XCTAssertEqual(configuration.legacySharedKeychainAccessGroups, [])
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
    }

    func testRootStorageInitializersRequireConcreteGroupAndExposeLegacyScanList() {
        let root = "ABCDE12345.com.example.latchway"
        let legacy = ["ABCDE12345.com.example.latchway.appintents"]
        _ = LatchwayInstallationKeyManager(
            applicationID: "app_01J00000000000000000000000",
            environment: "production",
            rootKeychainAccessGroup: root,
            legacySharedKeychainAccessGroups: legacy,
            softwareFallbackPolicy: .disallow
        )
        _ = LatchwayKeychainSessionStorage(
            applicationID: "app_01J00000000000000000000000",
            environment: "production",
            rootKeychainAccessGroup: root,
            legacySharedKeychainAccessGroups: legacy
        )
        let verify: (String, [String]) throws -> Void = {
            try LatchwayRootKeychainPreflight.verifySignedDefaultAccessGroup(
                $0,
                legacySharedKeychainAccessGroups: $1
            )
        }
        _ = verify
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

    func testKeychainNamespacesSeparateNativeAndReactNativeInstallations() {
        let native = LatchwayKeychainNamespace.service(
            applicationID: "app_01J00000000000000000000000",
            environment: "production",
            clientRuntime: .iOS
        )
        let reactNative = LatchwayKeychainNamespace.service(
            applicationID: "app_01J00000000000000000000000",
            environment: "production",
            clientRuntime: .reactNativeIOS
        )
        XCTAssertNotEqual(native, reactNative)
        XCTAssertTrue(native.contains(".ios."))
        XCTAssertTrue(reactNative.contains(".react_native_ios."))
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
