import Foundation
#if !COCOAPODS
import Latchway
#endif

/// A Firebase Auth adapter that keeps Firebase outside the core Latchway target.
///
/// Pass a `@Sendable` closure that obtains a current Firebase ID token. The
/// closure is the only Firebase-facing boundary, so applications keep control
/// of Firebase versioning and account selection.
public struct FirebaseLatchwayIdentityTokenProvider: LatchwayIdentityTokenProvider {
    public typealias TokenOperation = @Sendable () async throws -> String

    private let operation: TokenOperation

    public init(identityToken: @escaping TokenOperation) {
        operation = identityToken
    }

    public func identityToken() async throws -> String {
        let token = try await operation()
        guard !token.isEmpty else { throw LatchwayError.invalidRequest("Firebase returned an empty identity token") }
        return token
    }
}

public protocol FirebaseIdentityTokenSource: Sendable {
    func latchwayFirebaseIdentityToken() async throws -> String
}

public extension FirebaseLatchwayIdentityTokenProvider {
    init(source: any FirebaseIdentityTokenSource) {
        self.init { try await source.latchwayFirebaseIdentityToken() }
    }
}
