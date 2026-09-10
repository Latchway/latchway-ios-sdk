import Foundation
import XCTest

@testable import Latchway

final class RootKeychainPreflightTests: XCTestCase {
    private let root = "ABCDE12345.com.example.latchway"
    private let shared = "ABCDE12345.com.example.latchway.appintents"

    func testConcreteDistinctAccessGroupsValidate() throws {
        XCTAssertNoThrow(
            try LatchwayRootKeychainPreflight.validateAccessGroups(
                rootKeychainAccessGroup: root,
                componentKeychainAccessGroups: [shared]
            ))
    }

    func testWildcardBuildExpressionMalformedAndDuplicateGroupsFailClosed() {
        let invalid: [(String, [String])] = [
            ("$(AppIdentifierPrefix)com.example.app", []),
            ("ABCDE12345.*", []),
            ("ABCDE12345.com..example", []),
            ("ABCDE12345.com.example.", []),
            ("ABCDE12345.com.example\n", []),
            (" ABCDE12345.com.example", []),
            (root, [root]),
            (root, [shared, shared]),
        ]

        for (rootGroup, componentGroups) in invalid {
            XCTAssertThrowsError(
                try LatchwayRootKeychainPreflight.validateAccessGroups(
                    rootKeychainAccessGroup: rootGroup,
                    componentKeychainAccessGroups: componentGroups
                )
            ) { error in
                guard case .invalidConfiguration = error as? LatchwayError else {
                    return XCTFail("Expected invalid configuration, got \(error)")
                }
            }
        }
    }

    func testCorrectSignedDefaultSucceedsWithoutInspectingOtherRecords() throws {
        try LatchwayRootKeychainPreflight.verify(
            rootKeychainAccessGroup: root,
            probe: FakeRootKeychainProbe(matches: true))
    }

    func testDefaultMismatchFailsClosed() {
        XCTAssertThrowsError(
            try LatchwayRootKeychainPreflight.verify(
                rootKeychainAccessGroup: root,
                probe: FakeRootKeychainProbe(matches: false))
        ) { error in
            guard case .invalidConfiguration = error as? LatchwayError else {
                return XCTFail("Expected invalid private root configuration")
            }
        }
    }
}

private struct FakeRootKeychainProbe: LatchwayRootKeychainProbing {
    let matches: Bool
    func signedDefaultMatches(accessGroup: String) throws -> Bool { matches }
}
