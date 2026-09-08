import Foundation

/// A monotonic, process-local read fence. The lock protects the only mutable
/// field; no credentials live here. Stream iteration can check it synchronously
/// without hopping actors for every individual response byte. Persistent
/// retirement and cancellation registration remain owned by their actors.
final class LatchwayLifecycleReadFence: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: LatchwayLifecycleError?

    func check() throws {
        lock.lock()
        defer { lock.unlock() }
        if let failure { throw failure }
    }

    func retire(_ failure: LatchwayLifecycleError) {
        lock.lock()
        defer { lock.unlock() }
        if self.failure == nil { self.failure = failure }
    }
}

/// Owns only one client's dispatched feature work, never the shared refresh
/// task or a caller's unrelated URLSession. Buffered bytes are fenced too.
actor LatchwayClientLease {
    private nonisolated let fence = LatchwayLifecycleReadFence()
    private var cancellations: [UUID: @Sendable () -> Void] = [:]

    nonisolated func check() throws { try fence.check() }

    func register(_ cancel: @escaping @Sendable () -> Void) throws -> UUID {
        try check()
        let id = UUID()
        cancellations[id] = cancel
        return id
    }

    func unregister(_ id: UUID) { cancellations.removeValue(forKey: id) }

    func close() {
        fence.retire(.disposed)
        let pending = Array(cancellations.values)
        cancellations.removeAll()
        for cancel in pending { cancel() }
    }
}
