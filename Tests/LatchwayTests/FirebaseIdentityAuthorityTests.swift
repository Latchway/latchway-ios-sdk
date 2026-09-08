import Foundation
import XCTest
import Latchway
import LatchwayFirebaseAuth

final class FirebaseIdentityAuthorityTests: XCTestCase {
    @MainActor func testRejectsSwitchDuringTokenAcquisitionIncludingSameUID() async throws {
        for nextUID in ["A", "B"] {
            let source = FirebaseUserFixture()
            let provider = FirebaseLatchwayIdentityAuthority(projectID: "test-project",
                currentUser: { source.current }, userID: { $0.uid }, identityToken: { _ in
                    source.current = FirebaseUserFixture.User(uid: nextUID)
                    return "fixture-identity-token"
                })
            do { _ = try await provider.identitySnapshot(); XCTFail("Accepted a stale Firebase user") }
            catch let error as LatchwayLifecycleError { XCTAssertEqual(error, .accountChanged) }
        }
    }

    @MainActor func testSignedOutDoesNotFetchTokenAndSignedInSnapshotIsRedacted() async throws {
        let source = FirebaseUserFixture()
        let provider = FirebaseLatchwayIdentityAuthority(projectID: "test-project",
            currentUser: { source.current }, userID: { $0.uid }, identityToken: { _ in
                source.tokenCalls += 1
                return "fixture-identity-token"
            })
        let snapshot = try await provider.identitySnapshot()
        XCTAssertEqual(snapshot?.issuer, "https://securetoken.google.com/test-project")
        XCTAssertEqual(snapshot?.subject, "A")
        XCTAssertFalse(String(describing: snapshot).contains("fixture-identity-token"))
        source.current = nil
        let absent = try await provider.identitySnapshot()
        XCTAssertNil(absent)
        XCTAssertEqual(source.tokenCalls, 1)
    }
}

@MainActor private final class FirebaseUserFixture {
    final class User { let uid: String; init(uid: String) { self.uid = uid } }
    var current: User? = User(uid: "A")
    var tokenCalls = 0
}
