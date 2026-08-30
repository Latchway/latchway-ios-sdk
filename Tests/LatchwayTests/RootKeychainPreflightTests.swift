import Foundation
@testable import Latchway
import XCTest

final class RootKeychainPreflightTests: XCTestCase {
    private let root = "ABCDE12345.com.example.latchway"
    private let shared = "ABCDE12345.com.example.latchway.appintents"

    func testConcreteDistinctAccessGroupsValidate() throws {
        XCTAssertNoThrow(try LatchwayRootKeychainPreflight.validateAccessGroups(
            rootKeychainAccessGroup: root,
            legacySharedKeychainAccessGroups: [shared]
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

        for (rootGroup, legacyGroups) in invalid {
            XCTAssertThrowsError(try LatchwayRootKeychainPreflight.validateAccessGroups(
                rootKeychainAccessGroup: rootGroup,
                legacySharedKeychainAccessGroups: legacyGroups
            )) { error in
                guard case .invalidConfiguration = error as? LatchwayError else {
                    return XCTFail("Expected invalid configuration, got \(error)")
                }
            }
        }
    }

    func testCorrectDefaultStillRejectsRecordInExplicitLegacySharedGroup() {
        let record = LatchwayRootKeychainRecordCoordinate(
            service: "dev.latchway.sdk.ios.app.production",
            account: "session"
        )
        let probe = FakeRootKeychainProbe(
            signedDefaultMatches: true,
            records: [.init(group: shared, coordinate: record)]
        )

        XCTAssertThrowsError(try LatchwayRootKeychainPreflight.verify(
            rootKeychainAccessGroup: root,
            legacySharedKeychainAccessGroups: [shared],
            legacyRecordCoordinates: [record],
            probe: probe
        )) { error in
            XCTAssertEqual(error as? LatchwayError, .rootKeychainMigrationRequired)
        }
    }

    func testDefaultMismatchWithRecordInSuppliedRootGroupRequiresMigration() {
        let record = LatchwayRootKeychainRecordCoordinate(
            service: "dev.latchway.sdk.ios.app.production",
            account: "installation-key"
        )
        let probe = FakeRootKeychainProbe(
            signedDefaultMatches: false,
            records: [.init(group: root, coordinate: record)]
        )

        XCTAssertThrowsError(try LatchwayRootKeychainPreflight.verify(
            rootKeychainAccessGroup: root,
            legacySharedKeychainAccessGroups: [shared],
            legacyRecordCoordinates: [record],
            probe: probe
        )) { error in
            XCTAssertEqual(error as? LatchwayError, .rootKeychainMigrationRequired)
        }
    }

    func testDefaultMismatchWithoutLegacyRecordsIsInvalidConfiguration() {
        XCTAssertThrowsError(try LatchwayRootKeychainPreflight.verify(
            rootKeychainAccessGroup: root,
            legacySharedKeychainAccessGroups: [shared],
            legacyRecordCoordinates: [
                .init(service: "dev.latchway.sdk.ios.app.production", account: "session"),
            ],
            probe: FakeRootKeychainProbe(signedDefaultMatches: false)
        )) { error in
            guard case .invalidConfiguration = error as? LatchwayError else {
                return XCTFail("Expected invalid configuration, got \(error)")
            }
        }
    }

    func testStandardScanIncludesCoreAndAppAttestCoordinates() {
        let records = LatchwayRootKeychainPreflight.standardRootRecordCoordinates(
            applicationID: "app_01J00000000000000000000000",
            environment: "production",
            clientRuntime: .iOS
        )
        XCTAssertTrue(records.contains(where: { $0.account == "installation-key" }))
        XCTAssertTrue(records.contains(where: { $0.account == "installation-key-kind" }))
        XCTAssertTrue(records.contains(where: { $0.account == "session" }))
        XCTAssertTrue(records.contains(where: {
            $0.account == "app-attest-state" && $0.service.hasSuffix(".default")
        }))
        XCTAssertTrue(records.contains(where: {
            $0.account == "app-attest-state" && $0.service.contains(".ios.")
        }))
    }
}

private struct FakeRootKeychainProbe: LatchwayRootKeychainProbing {
    struct Record: Sendable, Hashable {
        let group: String
        let coordinate: LatchwayRootKeychainRecordCoordinate
    }

    let matches: Bool
    let records: Set<Record>

    init(signedDefaultMatches: Bool, records: Set<Record> = []) {
        matches = signedDefaultMatches
        self.records = records
    }

    func signedDefaultMatches(accessGroup: String) throws -> Bool { matches }

    func containsRecord(
        _ coordinate: LatchwayRootKeychainRecordCoordinate,
        accessGroup: String
    ) throws -> Bool {
        records.contains(.init(group: accessGroup, coordinate: coordinate))
    }
}
