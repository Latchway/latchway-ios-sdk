import Foundation
@testable import Latchway
import XCTest

final class StrictJSONTests: XCTestCase {
    func testAcceptsContractJSONShapes() throws {
        try StrictJSON.validate(Data(#"{"attestation":{"client_data_hash":"abc","mode":"required"},"binding_version":1,"enabled":true,"items":[null,-12.5e2]}"#.utf8))
    }

    func testRejectsDuplicateMembersIncludingEscapedAliases() {
        XCTAssertThrowsError(try StrictJSON.validate(Data(#"{"access_token":"first","access_token":"second"}"#.utf8)))
        XCTAssertThrowsError(try StrictJSON.validate(Data(#"{"token":"first","\u0074oken":"second"}"#.utf8)))
    }

    func testRejectsTrailingValuesInvalidNumbersAndExcessiveDepth() {
        XCTAssertThrowsError(try StrictJSON.validate(Data("{} {}".utf8)))
        XCTAssertThrowsError(try StrictJSON.validate(Data("01".utf8)))
        let nested = String(repeating: "[", count: 66) + String(repeating: "]", count: 66)
        XCTAssertThrowsError(try StrictJSON.validate(Data(nested.utf8)))
    }
}
