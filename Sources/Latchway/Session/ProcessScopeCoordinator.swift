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
        self.terminal = terminal
        return revision
    }

    func release(_ permit: LatchwayProcessScopePermit) {
        precondition(owner == permit.id, "Latchway process-scope permit is not the current owner")
        if waiters.isEmpty {
            owner = nil
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

    static func root(
        configuration: LatchwayConfiguration,
        namespace: String
    ) -> String {
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
        encode([
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
        encode([
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
