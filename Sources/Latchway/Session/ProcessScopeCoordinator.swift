import Foundation

struct LatchwayProcessScopePermit: Sendable, Hashable {
    fileprivate let id: UUID
}

struct LatchwayProcessScopeSnapshot<Value: Sendable>: Sendable {
    let revision: UInt64
    let value: Value?
    let terminal: Bool
}

/// Serializes mutations of one durable SDK namespace across independent
/// client actors in the current process.
///
/// The SDK intentionally keeps access tokens in memory, not in Keychain. The
/// small process cache therefore lets a second client join a completed
/// establishment or rotation without consuming the newly persisted refresh
/// credential immediately. `revision` invalidates actor-local caches after a
/// sibling client replaces or retires the durable state.
actor LatchwayProcessScopeCoordinator<Value: Sendable> {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<LatchwayProcessScopePermit, Error>
    }

    private let configurationFingerprint: String
    private var owner: UUID?
    private var waiters: [Waiter] = []
    private var revision: UInt64 = 0
    private var value: Value?
    private var terminal = false
    private var permanentlyRetired = false
    private struct DrainWaiter {
        let continuation: CheckedContinuation<Void, Error>
        let deadline: Task<Void, Never>
    }
    private var drainWaiters: [UUID: DrainWaiter] = [:]

    /// New shared-app registration retires a legacy runtime scope regardless
    /// of its former request options. It can never be reinitialized in-process.
    func retireForMigration() {
        permanentlyRetired = true
        terminal = true
        value = nil
        revision &+= 1
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.continuation.resume(throwing: LatchwayLifecycleError.loggedOut) }
    }

    /// Migration cannot erase credentials and declare success while an old
    /// owner can still finish a storage write. Timeout leaves the scope retired
    /// and the caller's durable migration journal pending for an explicit retry.
    func retireForMigrationAndDrain(timeoutNanoseconds: UInt64 = 30_000_000_000) async throws {
        retireForMigration()
        guard owner != nil else { return }
        let id = UUID()
        try await withCheckedThrowingContinuation { continuation in
            let deadline = Task {
                do { try await Task.sleep(nanoseconds: timeoutNanoseconds) }
                catch { return }
                self.expireDrain(id)
            }
            drainWaiters[id] = .init(continuation: continuation, deadline: deadline)
        }
    }

    private func expireDrain(_ id: UUID) {
        drainWaiters.removeValue(forKey: id)?.continuation.resume(throwing: LatchwayLifecycleError.cleanupRequired)
    }

    init(configurationFingerprint: String) {
        self.configurationFingerprint = configurationFingerprint
    }

    func snapshot() -> LatchwayProcessScopeSnapshot<Value> {
        LatchwayProcessScopeSnapshot(
            revision: revision,
            value: value,
            terminal: terminal
        )
    }

    func pendingWaiterCount() -> Int { waiters.count }

    func acquire(
        configurationFingerprint candidate: String
    ) async throws -> LatchwayProcessScopePermit {
        guard !permanentlyRetired else { throw LatchwayLifecycleError.loggedOut }
        guard candidate == configurationFingerprint else {
            throw LatchwayError.invalidConfiguration(
                "Clients sharing one Latchway Keychain namespace must use the same gateway and identity configuration"
            )
        }
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if owner == nil {
                    owner = id
                    continuation.resume(returning: LatchwayProcessScopePermit(id: id))
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    func snapshot(
        for permit: LatchwayProcessScopePermit
    ) -> LatchwayProcessScopeSnapshot<Value> {
        precondition(owner == permit.id, "Latchway process-scope permit is not the current owner")
        return snapshot()
    }

    @discardableResult
    func publish(_ value: Value, for permit: LatchwayProcessScopePermit) -> UInt64 {
        precondition(owner == permit.id, "Latchway process-scope permit is not the current owner")
        guard !permanentlyRetired else { return revision }
        revision &+= 1
        self.value = value
        terminal = false
        return revision
    }

    @discardableResult
    func invalidate(
        terminal: Bool,
        for permit: LatchwayProcessScopePermit
    ) -> UInt64 {
        precondition(owner == permit.id, "Latchway process-scope permit is not the current owner")
        revision &+= 1
        value = nil
        self.terminal = terminal || permanentlyRetired
        return revision
    }

    func release(_ permit: LatchwayProcessScopePermit) {
        precondition(owner == permit.id, "Latchway process-scope permit is not the current owner")
        if waiters.isEmpty {
            owner = nil
            let pending = Array(drainWaiters.values)
            drainWaiters.removeAll()
            for waiter in pending { waiter.deadline.cancel(); waiter.continuation.resume() }
            return
        }
        let waiter = waiters.removeFirst()
        owner = waiter.id
        waiter.continuation.resume(returning: LatchwayProcessScopePermit(id: waiter.id))
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            // A granted owner releases in the operation's catch/defer path.
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}

final class LatchwayProcessScopeCoordinatorPool: @unchecked Sendable {
    static let shared = LatchwayProcessScopeCoordinatorPool()

    private let lock = NSLock()
    private var rootScopes: [String: LatchwayProcessScopeCoordinator<RuntimeSession>] = [:]
    private var componentScopes: [
        String: LatchwayProcessScopeCoordinator<LatchwayComponentRuntimeSession>
    ] = [:]

    func root(
        identity: String,
        configurationFingerprint: String
    ) -> LatchwayProcessScopeCoordinator<RuntimeSession> {
        lock.lock()
        defer { lock.unlock() }
        if let existing = rootScopes[identity] { return existing }
        let created = LatchwayProcessScopeCoordinator<RuntimeSession>(
            configurationFingerprint: configurationFingerprint
        )
        rootScopes[identity] = created
        return created
    }

    func component(
        identity: String,
        configurationFingerprint: String
    ) -> LatchwayProcessScopeCoordinator<LatchwayComponentRuntimeSession> {
        lock.lock()
        defer { lock.unlock() }
        if let existing = componentScopes[identity] { return existing }
        let created = LatchwayProcessScopeCoordinator<LatchwayComponentRuntimeSession>(
            configurationFingerprint: configurationFingerprint
        )
        componentScopes[identity] = created
        return created
    }
}

enum LatchwayProcessScopeIdentity {
    static let productionNamespace = "production"

    static func sharedRoot(scope: String, generation: UUID, namespace: String = productionNamespace) -> String {
        encode([namespace, "shared-native-v3", scope, generation.uuidString])
    }

    static func sharedFingerprint(scope: String, generation: UUID) -> String {
        encode(["shared-native-v3", scope, generation.uuidString])
    }

    static func root(
        configuration: LatchwayConfiguration,
        namespace: String
    ) -> String {
        if let generation = configuration.accountGeneration {
            return sharedRoot(scope: generation.storageScope, generation: generation.id, namespace: namespace)
        }
        let service = LatchwayKeychainNamespace.service(
            applicationID: configuration.applicationID,
            environment: configuration.environment,
            clientRuntime: configuration.clientRuntime
        )
        return encode([
            namespace,
            "root",
            service,
            configuration.rootKeychainAccessGroup,
        ])
    }

    static func component(
        configuration: LatchwayConfiguration,
        component: LatchwayComponentConfiguration,
        namespace: String
    ) -> String {
        if let account = configuration.sharedComponentAccount {
            return encode([namespace, account.service(component), account.generationID.uuidString,
                           component.keychainAccessGroup])
        }
        let service = LatchwayKeychainNamespace.componentService(
            applicationID: configuration.applicationID,
            environment: configuration.environment,
            definitionID: component.definitionID
        )
        return encode([
            namespace,
            "component",
            service,
            component.keychainAccessGroup,
        ])
    }

    static func rootFingerprint(configuration: LatchwayConfiguration) -> String {
        if let generation = configuration.accountGeneration {
            return sharedFingerprint(scope: generation.storageScope, generation: generation.id)
        }
        return encode([
            configuration.baseURL.absoluteString,
            configuration.applicationID,
            configuration.environment,
            encode(configuration.legacySharedKeychainAccessGroups.sorted()),
            configuration.identityProvider,
            configuration.clientRuntime.rawValue,
            configuration.clientSDKVersion,
            configuration.appVersion,
            configuration.softwareKeyFallbackPolicy.rawValue,
            String(configuration.controlRequestTimeout.bitPattern),
        ])
    }

    static func componentFingerprint(
        configuration: LatchwayConfiguration,
        component: LatchwayComponentConfiguration
    ) -> String {
        if let account = configuration.sharedComponentAccount {
            return encode([account.appScope, account.accountScope, account.generationID.uuidString,
                           component.definitionID, component.kind, encode(component.requestedFeatures.sorted())])
        }
        return encode([
            rootFingerprint(configuration: configuration),
            component.definitionID,
            component.kind,
            encode(component.requestedFeatures.sorted()),
        ])
    }

    /// Length-prefixing keeps different field tuples from aliasing even when
    /// caller-controlled identifiers contain separator characters.
    private static func encode(_ fields: [String]) -> String {
        fields.map { "\($0.utf8.count):\($0)" }.joined()
    }
}
