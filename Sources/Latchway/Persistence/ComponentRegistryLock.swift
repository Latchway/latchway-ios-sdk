import Foundation

actor LatchwayComponentRegistryMutex {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

final class LatchwayComponentRegistryLockPool: @unchecked Sendable {
    static let shared = LatchwayComponentRegistryLockPool()

    private let lock = NSLock()
    private var locks: [String: LatchwayComponentRegistryMutex] = [:]

    func mutex(for identity: String) -> LatchwayComponentRegistryMutex {
        lock.lock()
        defer { lock.unlock() }
        if let existing = locks[identity] { return existing }
        let created = LatchwayComponentRegistryMutex()
        locks[identity] = created
        return created
    }
}
