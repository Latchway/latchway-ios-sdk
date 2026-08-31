import Foundation
import LatchwayGoldenJourneyExample
import XCTest

final class GoldenJourneyCompilationTests: XCTestCase {
    func testSetupWizardCoordinatesRemainExplicit() throws {
        let configuration = LatchwayGoldenJourneyConfiguration(
            baseURL: try XCTUnwrap(URL(string: "https://gateway.example.test")),
            applicationID: "app_01J00000000000000000000000",
            environment: "production",
            rootKeychainAccessGroup: "ABCDE12345.com.example.app",
            feature: "assistant-responses",
            model: "assistant-default",
            appVersion: "1.0.0"
        )

        XCTAssertEqual(configuration.baseURL.host, "gateway.example.test")
        XCTAssertEqual(configuration.applicationID, "app_01J00000000000000000000000")
        XCTAssertEqual(configuration.rootKeychainAccessGroup, "ABCDE12345.com.example.app")
        XCTAssertEqual(configuration.feature, "assistant-responses")
        XCTAssertEqual(configuration.model, "assistant-default")
    }
}
