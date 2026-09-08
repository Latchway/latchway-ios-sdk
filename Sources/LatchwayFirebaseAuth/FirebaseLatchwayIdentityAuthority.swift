import Foundation
#if !COCOAPODS
import Latchway
#endif

/// Account-aware Firebase adapter without imposing a Firebase dependency/version.
/// All Firebase access runs on the main actor. Capture one named Auth instance
/// in the closures; never resolve a different default Auth during token retrieval.
public struct FirebaseLatchwayIdentityAuthority<User: AnyObject>: LatchwayIdentityAuthority {
    private let projectID: String
    private let currentUser: @MainActor @Sendable () -> User?
    private let userID: @MainActor @Sendable (User) -> String
    private let tenantID: @MainActor @Sendable (User) -> String?
    private let token: @MainActor @Sendable (User) async throws -> String

    public init(projectID: String,
                currentUser: @escaping @MainActor @Sendable () -> User?,
                userID: @escaping @MainActor @Sendable (User) -> String,
                tenantID: @escaping @MainActor @Sendable (User) -> String? = { _ in nil },
                identityToken: @escaping @MainActor @Sendable (User) async throws -> String) {
        self.projectID = projectID
        self.currentUser = currentUser
        self.userID = userID
        self.tenantID = tenantID
        token = identityToken
    }

    public func identitySnapshot() async throws -> LatchwayIdentitySnapshot? {
        try await readSnapshot()
    }

    @MainActor private func readSnapshot() async throws -> LatchwayIdentitySnapshot? {
        guard !projectID.isEmpty else { throw LatchwayLifecycleError.identityUnavailable }
        guard let user = currentUser() else { return nil }
        let uid = userID(user)
        let tenant = tenantID(user)
        let value = try await token(user)
        // Compare object identity as well as UID/tenant. Sign-out followed by
        // another sign-in to the same UID must not accept the old user's task.
        guard currentUser() === user, userID(user) == uid, tenantID(user) == tenant else {
            throw LatchwayLifecycleError.accountChanged
        }
        guard !uid.isEmpty, value.utf8.count >= 16, value.utf8.count <= 65_536 else {
            throw LatchwayLifecycleError.identityUnavailable
        }
        return .init(issuer: "https://securetoken.google.com/\(projectID)", tenant: tenant, subject: uid, token: value)
    }
}
