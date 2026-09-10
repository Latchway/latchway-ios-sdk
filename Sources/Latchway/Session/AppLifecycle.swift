import CryptoKit
import Foundation

/// Local lifecycle errors. These are not server error codes.
public enum LatchwayLifecycleError: Error, Sendable, Equatable {
    case appNotConfigured
    case configurationConflict
    case identityUnavailable
    case identityRefreshRequired
    case identityVerificationUnsupported
    case accountChanged
    case loggedOut
    case cleanupRequired
    case disposed
}

/// An atomic snapshot supplied by the application's authentication owner.
/// The binding is an isolation hint; only the gateway authenticates the token.
struct LatchwayIdentitySnapshot: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let issuer: String
    public let tenant: String?
    public let subject: String
    public let token: String
    public var description: String { "LatchwayIdentitySnapshot([REDACTED])" }
    public var debugDescription: String { description }

    public init(issuer: String, tenant: String? = nil, subject: String, token: String) {
        self.issuer = issuer
        self.tenant = tenant
        self.subject = subject
        self.token = token
    }

    func binding(expectedIssuer: String, expectedTenant: String?) throws -> String {
        guard issuer == expectedIssuer, tenant == expectedTenant,
              !issuer.isEmpty, !subject.isEmpty, !token.isEmpty else {
            throw LatchwayLifecycleError.identityUnavailable
        }
        return LatchwayAppIdentity.digest([issuer, tenant ?? "", subject])
    }
}

protocol LatchwayIdentityState: Sendable {
    func identitySnapshot() async throws -> LatchwayIdentitySnapshot?
    var freshness: LatchwayIdentityFreshnessFence { get }
}

/// Public, non-secret lifecycle state suitable for a React Native bridge.
public struct LatchwayAppSnapshot: Sendable, Equatable, Codable {
    public enum State: String, Sendable, Codable { case inactive, active, refreshRequired, retiring, loggedOut }
    public let appInstanceID: UUID
    public let generationID: UUID?
    public let revision: UInt64
    public let state: State
}

enum LatchwayAppIdentity {
    static func digest(_ fields: [String]) -> String {
        let tuple = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(tuple.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func canonicalURL(_ url: URL) throws -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host))
        else { throw LatchwayError.invalidConfiguration("Invalid gateway URL") }
        parts.scheme = scheme
        parts.host = host
        if parts.port == (scheme == "https" ? 443 : 80) { parts.port = nil }
        // Preserve the gateway path prefix. Reject ambiguous dot/encoded path
        // separators rather than creating two security scopes for one endpoint.
        let path = parts.percentEncodedPath
        guard !path.lowercased().contains("%2f"), !path.lowercased().contains("%5c"),
              !path.contains("\\"), !path.contains("//"),
              !path.split(separator: "/").contains(where: {
                  let decoded = String($0).removingPercentEncoding
                  return decoded == "." || decoded == ".."
              }) else { throw LatchwayError.invalidConfiguration("Ambiguous gateway path") }
        parts.percentEncodedPath = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let result = parts.url else { throw LatchwayError.invalidConfiguration("Invalid gateway URL") }
        return result
    }
}

/// Synchronous durable operations are owned by AppSessionJournal's actor. They
/// must either commit a complete value or throw; no check/write suspension gap.
protocol LatchwayLifecycleRecords: Sendable {
    func read() throws -> Data?
    func write(_ data: Data) throws
}

struct LatchwayKeychainLifecycleRecords: LatchwayLifecycleRecords {
    let records: LatchwayKeychainRecords
    func read() throws -> Data? { try records.read(account: "account-lifecycle-v3") }
    func write(_ data: Data) throws { try records.write(data, account: "account-lifecycle-v3") }
}

actor LatchwayAppSessionJournal {
    struct Entry: Codable, Sendable {
        var generation: UUID
        var account: String
        var state: LatchwayAppSnapshot.State
        var session: LatchwayStoredSession?
        var components: [RegisteredComponent]?
    }

    struct RegisteredComponent: Codable, Sendable {
        let account: LatchwayComponentAccount
        let configuration: LatchwayComponentConfiguration
    }

    private let records: any LatchwayLifecycleRecords
    private let componentState: @Sendable (LatchwayComponentAccount, LatchwayComponentConfiguration) -> LatchwaySharedComponentState
    private let componentKeyIndex: LatchwaySharedComponentKeyIndex?
    private var blocked = false
    private var identityOperation: UUID?

    init(records: any LatchwayLifecycleRecords,
         componentKeyIndex: LatchwaySharedComponentKeyIndex? = nil,
         componentState: @escaping @Sendable (LatchwayComponentAccount, LatchwayComponentConfiguration) -> LatchwaySharedComponentState = {
             LatchwaySharedComponentState(account: $0, component: $1)
         }) {
        self.records = records
        self.componentState = componentState
        self.componentKeyIndex = componentKeyIndex
    }

    func entry() throws -> Entry? {
        do {
            guard let data = try records.read() else { return nil }
            guard data.count <= 524_288, (try? StrictJSON.validate(data)) != nil else {
                throw LatchwayLifecycleError.cleanupRequired
            }
            let entry = try JSONDecoder().decode(Entry.self, from: data)
            guard (entry.components?.count ?? 0) <= 256 else { throw LatchwayLifecycleError.cleanupRequired }
            var coordinates = Set<String>()
            for item in entry.components ?? [] {
                try item.configuration.validateForContainingApplication()
                guard item.account.generationID == entry.generation,
                      item.account.accountScope.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                      item.account.appScope.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                      coordinates.insert(item.account.service(item.configuration) + "|" + item.configuration.keychainAccessGroup).inserted
                else { throw LatchwayLifecycleError.cleanupRequired }
            }
            return entry
        } catch { blocked = true; throw LatchwayLifecycleError.cleanupRequired }
    }

    func beginIdentityOperation(_ id: UUID) { identityOperation = id }
    func cancelIdentityOperation(_ id: UUID) { if identityOperation == id { identityOperation = nil } }
    func fenceSignOut() {
        identityOperation = nil
        blocked = true
    }

    func activate(account: String, identityTicket: UUID? = nil) throws -> Entry {
        if let identityTicket, identityOperation != identityTicket { throw LatchwayLifecycleError.accountChanged }
        try checkActivation(account: account)
        if let previous = try entry(), previous.state == .active { return previous }
        let next = Entry(generation: UUID(), account: account, state: .active, session: nil)
        try persist(next)
        return next
    }

    func recordEmptyLogout() throws {
        if let entry = try entry() {
            guard entry.state == .loggedOut else { throw LatchwayLifecycleError.cleanupRequired }
            blocked = false
            return
        }
        try persist(Entry(generation: UUID(), account: "", state: .loggedOut, session: nil))
        blocked = false
    }

    func checkActivation(account: String) throws {
        guard !blocked else { throw LatchwayLifecycleError.cleanupRequired }
        if let previous = try entry() {
            guard previous.state != .retiring else { throw LatchwayLifecycleError.cleanupRequired }
            if previous.state == .active {
                guard previous.account == account else { throw LatchwayLifecycleError.accountChanged }
            }
        }
    }

    func check(_ generation: UUID) throws {
        guard !blocked else { throw LatchwayLifecycleError.cleanupRequired }
        guard let current = try entry(), current.generation == generation, current.state == .active else {
            throw LatchwayLifecycleError.loggedOut
        }
    }

    /// Fence and removal of root credentials are one durable atomic write.
    /// Remain blocked in memory even if that write fails; retry retirement.
    func retire(_ generation: UUID) throws {
        guard var current = try entry(), current.generation == generation else { return }
        blocked = true
        current.state = .retiring
        current.session = nil
        try persist(current)
    }

    func finishRetirement(_ generation: UUID) throws {
        guard var current = try entry(), current.generation == generation else { return }
        guard current.state == .retiring || current.state == .loggedOut else {
            throw LatchwayLifecycleError.cleanupRequired
        }
        try retireComponents(generation)
        current.state = .loggedOut
        current.session = nil
        current.components = nil
        try persist(current)
        blocked = false
    }

    func load(_ generation: UUID) throws -> LatchwayStoredSession? {
        try check(generation)
        return try entry()?.session
    }

    func save(_ value: LatchwayStoredSession, generation: UUID) throws {
        try check(generation)
        guard var current = try entry() else { throw LatchwayLifecycleError.loggedOut }
        current.session = value
        try persist(current)
    }

    func clear(_ generation: UUID) throws {
        guard var current = try entry(), current.generation == generation else { return }
        current.session = nil
        try persist(current)
    }

    func registerComponent(_ component: LatchwayComponentConfiguration,
                           account: LatchwayComponentAccount) throws {
        try check(account.generationID)
        try component.validateForContainingApplication()
        guard var current = try entry() else { throw LatchwayLifecycleError.loggedOut }
        var components = current.components ?? []
        if let existing = components.first(where: {
            $0.configuration.definitionID == component.definitionID &&
            $0.configuration.keychainAccessGroup == component.keychainAccessGroup
        }) {
            guard existing.account == account, existing.configuration == component else {
                throw LatchwayLifecycleError.configurationConflict
            }
        } else {
            guard components.count < 256 else { throw LatchwayLifecycleError.configurationConflict }
            components.append(.init(account: account, configuration: component))
            current.components = components
            // Registration precedes the first component-local mutation. Both
            // operations are synchronous under this actor; retirement cannot
            // miss an initialization that is awaiting an actor suspension.
            try persist(current)
        }
        try componentKeyIndex?.register(account: account, component: component)
        try componentState(account, component).initialize()
    }

    func retireComponents(_ generation: UUID) throws {
        guard let current = try entry(), current.generation == generation else { return }
        guard current.state == .retiring || current.state == .loggedOut else {
            throw LatchwayLifecycleError.cleanupRequired
        }
        var failed = false
        for item in current.components ?? [] {
            do {
                try item.configuration.validateForContainingApplication()
                guard item.account.generationID == generation else { throw LatchwayLifecycleError.cleanupRequired }
                try componentState(item.account, item.configuration).retire()
            } catch { failed = true }
        }
        if failed { throw LatchwayLifecycleError.cleanupRequired }
    }

    func registeredComponents(_ generation: UUID) throws -> [LatchwayComponentConfiguration] {
        try check(generation)
        return try entry()?.components?.map(\.configuration) ?? []
    }

    private func persist(_ entry: Entry) throws {
        do { try records.write(JSONEncoder().encode(entry)) }
        catch { blocked = true; throw LatchwayLifecycleError.cleanupRequired }
    }
}

struct LatchwayGenerationSessionStorage: LatchwaySessionStorage {
    let journal: LatchwayAppSessionJournal
    let generation: UUID
    func load() async throws -> LatchwayStoredSession? { try await journal.load(generation) }
    func save(_ session: LatchwayStoredSession) async throws { try await journal.save(session, generation: generation) }
    func clear() async throws { try await journal.clear(generation) }
}

actor LatchwayAccountGeneration: LatchwayIdentityTokenProvider {
    nonisolated let id: UUID
    nonisolated let storageScope: String
    private let account: String
    private let issuer: String
    private let tenant: String?
    private let identityState: any LatchwayIdentityState
    private let journal: LatchwayAppSessionJournal
    private let cleanup: @Sendable () async throws -> Void
    private let onIdentityLoss: (@Sendable () async -> Void)?
    private var retired = false
    private nonisolated let readFence = LatchwayLifecycleReadFence()
    private nonisolated let freshnessFence: LatchwayIdentityFreshnessFence
    private var completed = false
    private var logoutTask: Task<Void, Never>?
    private struct LogoutWaiter {
        let continuation: CheckedContinuation<Void, Error>
        let deadline: Task<Void, Never>
    }
    private var logoutWaiters: [UUID: LogoutWaiter] = [:]
    private let cleanupTimeoutNanoseconds: UInt64
    private var cancellers: [UUID: @Sendable () -> Void] = [:]
    private struct ClientCleanup {
        weak var client: LatchwayClient?
        let action: @Sendable () async -> Void
    }
    private var clientCleanups: [ClientCleanup] = []

    init(entry: LatchwayAppSessionJournal.Entry, scope: String, issuer: String, tenant: String?,
         identityState: any LatchwayIdentityState, journal: LatchwayAppSessionJournal,
         accountBinding: String? = nil,
         cleanupTimeoutNanoseconds: UInt64 = 30_000_000_000,
         onIdentityLoss: (@Sendable () async -> Void)? = nil,
         cleanup: @escaping @Sendable () async throws -> Void) {
        id = entry.generation
        storageScope = scope
        account = accountBinding ?? entry.account
        self.issuer = issuer
        self.tenant = tenant
        self.identityState = identityState
        freshnessFence = identityState.freshness
        self.journal = journal
        self.cleanup = cleanup
        self.onIdentityLoss = onIdentityLoss
        self.cleanupTimeoutNanoseconds = cleanupTimeoutNanoseconds
    }

    func check() async throws {
        try readFence.check()
        guard !retired else { throw LatchwayLifecycleError.loggedOut }
        try await journal.check(id)
        try readFence.check()
        guard !retired else { throw LatchwayLifecycleError.loggedOut }
    }

    nonisolated func checkLive() throws { try readFence.check(); try freshnessFence.check() }
    /// App-level intent must fence buffered reads before its first actor hop.
    nonisolated func fenceSignOut() { readFence.retire(.loggedOut) }

    func registerComponent(_ component: LatchwayComponentConfiguration, account: LatchwayComponentAccount) async throws {
        try await check()
        try await journal.registerComponent(component, account: account)
        try await check()
    }

    func registeredComponents() async throws -> [LatchwayComponentConfiguration] {
        try await journal.registeredComponents(id)
    }

    func identityToken() async throws -> String {
        try await check()
        let current: LatchwayIdentitySnapshot?
        do { current = try await identityState.identitySnapshot() }
        catch let error as LatchwayLifecycleError where error == .accountChanged || error == .identityUnavailable {
            try await identityWasLost()
            throw error
        }
        guard let snapshot = current else {
            try await identityWasLost()
            throw LatchwayLifecycleError.identityUnavailable
        }
        let binding: String
        do { binding = try snapshot.binding(expectedIssuer: issuer, expectedTenant: tenant) }
        catch { try await identityWasLost(); throw error }
        guard binding == account else {
            try await identityWasLost()
            throw LatchwayLifecycleError.accountChanged
        }
        try await check()
        return snapshot.token
    }

    private func identityWasLost() async throws {
        guard !retired else { throw LatchwayLifecycleError.loggedOut }
        retired = true
        readFence.retire(.loggedOut)
        // Do not await a drain from the request being drained. Persist the
        // fence first; background app cleanup observes and completes retirement.
        Task {
            if let onIdentityLoss { await onIdentityLoss() }
            else { try? await self.logout() }
        }
        try await journal.retire(id)
    }

    func registerCancellation(_ cancellation: @escaping @Sendable () -> Void) async throws -> UUID {
        try await check()
        let key = UUID()
        cancellers[key] = cancellation
        return key
    }
    func unregisterCancellation(_ key: UUID) { cancellers.removeValue(forKey: key) }

    func registerClientCleanup(for client: LatchwayClient, _ cleanup: @escaping @Sendable () async -> Void) async throws {
        try await check()
        clientCleanups.removeAll { $0.client == nil }
        clientCleanups.append(.init(client: client, action: cleanup))
    }

    func logout() async throws {
        if completed { return }
        if logoutTask == nil {
            retired = true
            readFence.retire(.loggedOut)
            for cancel in cancellers.values { cancel() }
            cancellers.removeAll()
            // Exactly one cleanup task outlives UI cancellation and deadline
            // expiry. A timed-out caller cannot open B while it is draining.
            let clientCleanups = self.clientCleanups.filter { $0.client != nil }.map(\.action)
            logoutTask = Task { [journal, id, cleanup] in
                let result: Result<Void, Error>
                do {
                    try await journal.retire(id)
                    for clearClient in clientCleanups { await clearClient() }
                    try await cleanup()
                    try await journal.finishRetirement(id)
                    result = .success(())
                } catch { result = .failure(LatchwayLifecycleError.cleanupRequired) }
                self.finishLogout(result)
            }
        }
        let waiter = UUID()
        try await withCheckedThrowingContinuation { continuation in
            let deadline = Task {
                do { try await Task.sleep(nanoseconds: cleanupTimeoutNanoseconds) }
                catch { return }
                self.expireLogoutWaiter(waiter)
            }
            logoutWaiters[waiter] = .init(continuation: continuation, deadline: deadline)
        }
    }

    private func expireLogoutWaiter(_ id: UUID) {
        logoutWaiters.removeValue(forKey: id)?.continuation.resume(throwing: LatchwayLifecycleError.cleanupRequired)
    }

    private func finishLogout(_ result: Result<Void, Error>) {
        if case .success = result { completed = true; clientCleanups.removeAll() }
        logoutTask = nil
        let waiters = logoutWaiters.values
        logoutWaiters.removeAll()
        for waiter in waiters {
            waiter.deadline.cancel()
            waiter.continuation.resume(with: result)
        }
    }
}
