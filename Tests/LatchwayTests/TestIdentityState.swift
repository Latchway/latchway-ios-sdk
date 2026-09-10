import Foundation
@testable import Latchway

/// Fixture-only state source for isolated generation/cancellation unit tests.
struct TestIdentityState: LatchwayIdentityState {
    let freshness = LatchwayIdentityFreshnessFence()
    private let operation: @Sendable () async throws -> LatchwayIdentitySnapshot?
    init(_ operation: @escaping @Sendable () async throws -> LatchwayIdentitySnapshot?) {
        self.operation = operation
        freshness.commit(Date.distantFuture)
    }
    func identitySnapshot() async throws -> LatchwayIdentitySnapshot? { try await operation() }
}
