import Foundation

/// Omitted settings inherit an existing registration. On first registration,
/// rootKeychainAccessGroup and suppliedIdentity are required.
public struct LatchwayAppOptions: Sendable {
    public let baseURL: URL
    public let applicationID: String
    public let environment: String
    public var rootKeychainAccessGroup: String?
    public var suppliedIdentity: LatchwaySuppliedIdentityConfiguration?
    public var identityProvider: String?
    public var attestationPolicyID: String?
    public var softwareKeyFallbackPolicy: LatchwaySoftwareKeyFallbackPolicy?
    public var exposeToReactNative: Bool?
    public var componentKeychainAccessGroups: [String]?

    public init(baseURL: URL, applicationID: String, environment: String,
                rootKeychainAccessGroup: String? = nil,
                suppliedIdentity: LatchwaySuppliedIdentityConfiguration? = nil,
                identityProvider: String? = nil,
                attestationPolicyID: String? = nil,
                softwareKeyFallbackPolicy: LatchwaySoftwareKeyFallbackPolicy? = nil,
                exposeToReactNative: Bool? = nil,
                componentKeychainAccessGroups: [String]? = nil) {
        self.baseURL = baseURL
        self.applicationID = applicationID
        self.environment = environment
        self.rootKeychainAccessGroup = rootKeychainAccessGroup
        self.suppliedIdentity = suppliedIdentity
        self.identityProvider = identityProvider
        self.attestationPolicyID = attestationPolicyID
        self.softwareKeyFallbackPolicy = softwareKeyFallbackPolicy
        self.exposeToReactNative = exposeToReactNative
        self.componentKeychainAccessGroups = componentKeychainAccessGroups
    }
}

/// Creates attestation state for the exact supplied account scope. A factory
/// must not return one global provider for different account namespaces.
public typealias LatchwayAccountAttestationFactory = @Sendable (String) -> any LatchwayAttestationProvider

public actor LatchwayAppRegistry {
    public static let shared = LatchwayAppRegistry()
    public static let defaultName = "[DEFAULT]"
    private var names: [String: LatchwayApp] = [:]
    private var scopes: [String: LatchwayApp] = [:]

    private init() {}

    public func configure(
        _ options: LatchwayAppOptions,
        name: String = defaultName,
        attestationFactory: LatchwayAccountAttestationFactory? = nil,
        fromReactNative: Bool = false
    ) throws -> LatchwayApp {
        let resolved = try LatchwayAppRegistration(options)
        guard !name.isEmpty, name.utf8.count <= 128 else { throw LatchwayLifecycleError.configurationConflict }
        if let existing = names[name] {
            try existing.registration.compare(resolved, fromReactNative: fromReactNative)
            return existing
        }
        if let existing = scopes[resolved.scope] {
            try existing.registration.compare(resolved, fromReactNative: fromReactNative)
            names[name] = existing
            return existing
        }
        guard resolved.suppliedIdentity != nil, let attestationFactory, let root = resolved.rootGroup else {
            throw LatchwayLifecycleError.configurationConflict
        }
        if fromReactNative, resolved.expose == false { throw LatchwayLifecycleError.configurationConflict }
        try LatchwayRootKeychainPreflight.verifySignedDefaultAccessGroup(root)
        try LatchwayRootKeychainPreflight.validateAccessGroups(rootKeychainAccessGroup: root,
            componentKeychainAccessGroups: resolved.componentGroups ?? [])
        let registration = resolved.effective()
        let app = try LatchwayApp(registration: registration,
                              attestationFactory: attestationFactory)
        scopes[registration.scope] = app
        names[name] = app
        return app
    }

    public func getApp(_ name: String = defaultName, fromReactNative: Bool = false) throws -> LatchwayApp {
        guard let app = names[name] else { throw LatchwayLifecycleError.appNotConfigured }
        guard !fromReactNative || app.registration.expose == true else {
            throw LatchwayLifecycleError.configurationConflict
        }
        return app
    }
}

struct LatchwayAppRegistration: Sendable {
    let baseURL: URL
    let applicationID: String
    let environment: String
    var rootGroup: String?
    let suppliedIdentity: LatchwaySuppliedIdentityConfiguration?
    var identityProvider: String?
    var attestationPolicyID: String?
    var fallback: LatchwaySoftwareKeyFallbackPolicy?
    var expose: Bool?
    var componentGroups: [String]?
    var scope: String { LatchwayAppIdentity.digest([baseURL.absoluteString, applicationID, environment]) }

    init(_ options: LatchwayAppOptions) throws {
        baseURL = try LatchwayAppIdentity.canonicalURL(options.baseURL)
        guard !options.applicationID.isEmpty, !options.environment.isEmpty else {
            throw LatchwayLifecycleError.configurationConflict
        }
        applicationID = options.applicationID
        environment = options.environment
        rootGroup = options.rootKeychainAccessGroup
        suppliedIdentity = options.suppliedIdentity
        try suppliedIdentity?.validate()
        guard options.identityProvider == nil || suppliedIdentity == nil || options.identityProvider == suppliedIdentity?.providerID else {
            throw LatchwayLifecycleError.configurationConflict
        }
        identityProvider = options.identityProvider ?? suppliedIdentity?.providerID
        attestationPolicyID = options.attestationPolicyID
        fallback = options.softwareKeyFallbackPolicy
        expose = options.exposeToReactNative
        componentGroups = options.componentKeychainAccessGroups?.sorted()
        guard (componentGroups?.count ?? 0) <= 256 else {
            throw LatchwayLifecycleError.configurationConflict
        }
    }

    func effective() -> Self {
        var copy = self
        copy.identityProvider = identityProvider ?? "firebase"
        copy.attestationPolicyID = attestationPolicyID ?? "app-attest"
        copy.fallback = fallback ?? .disallow
        copy.expose = expose ?? true
        copy.componentGroups = componentGroups ?? []
        return copy
    }

    func compare(_ supplied: Self, fromReactNative: Bool) throws {
        guard scope == supplied.scope,
              supplied.rootGroup == nil || supplied.rootGroup == rootGroup,
              supplied.suppliedIdentity == nil || supplied.suppliedIdentity == suppliedIdentity,
              supplied.identityProvider == nil || supplied.identityProvider == identityProvider,
              supplied.attestationPolicyID == nil || supplied.attestationPolicyID == attestationPolicyID,
              supplied.fallback == nil || supplied.fallback == fallback,
              supplied.expose == nil || supplied.expose == expose,
              supplied.componentGroups == nil || supplied.componentGroups == componentGroups,
              !fromReactNative || expose == true else {
            throw LatchwayLifecycleError.configurationConflict
        }
    }

}

/// Process-wide app backend. Configuration never activates an account. Native
/// and React Native clients are leases on its account-bound session generation.
public actor LatchwayApp {
    public nonisolated let instanceID = UUID()
    nonisolated let registration: LatchwayAppRegistration
    public nonisolated var baseURL: URL { registration.baseURL }
    public nonisolated var applicationID: String { registration.applicationID }
    public nonisolated var environment: String { registration.environment }
    public nonisolated var identityMode: String { "supplied" }
    /// The native owner's approved component groups, not root credentials or
    /// inferred JS defaults. Actual entitlement access is enforced by Keychain.
    public nonisolated var componentKeychainAccessGroups: [String] { registration.componentGroups ?? [] }
    private let identityState = LatchwaySuppliedIdentityState()
    private let attestationFactory: LatchwayAccountAttestationFactory
    private let journal: LatchwayAppSessionJournal
    private let sharedRecords: LatchwayKeychainRecords
    private let keyRetention: LatchwayAccountKeyRetention
    private var generation: LatchwayAccountGeneration?
    private var persistedGenerationID: UUID?
    private var installationKey: (any LatchwayInstallationKey)?
    private var attestation: (any LatchwayAttestationProvider)?
    private var revision: UInt64 = 0
    private var state: LatchwayAppSnapshot.State = .inactive
    private var activationEpoch: UUID?
    private var signOutTask: Task<Void, Error>?
    private var observers: [UUID: AsyncStream<LatchwayAppSnapshot>.Continuation] = [:]
    private struct IdentityOperation {
        let id: UUID
        let intent: LatchwayIdentityIntent
        let generationID: UUID?
        let bindingID: UUID?
    }
    private var identityOperation: IdentityOperation?
    private var verificationTask: Task<LatchwayVerifiedIdentityWire, Error>?
    private var identityExpiryTask: Task<Void, Never>?
    private var identityBindingID: UUID?
    private var identityIntentEpoch = UUID()
    private var verifiedGenerationID: UUID?
    private let accountPreparationOverride: (@Sendable (String) async throws -> Void)?
    private let identityVerificationOverride: (@Sendable (String) async throws -> LatchwayVerifiedIdentityWire)?
    private let cleanupTimeoutNanoseconds: UInt64

    public func signIn(idToken: String) async throws -> LatchwayAccount {
        try await signIn { idToken }
    }

    public func signIn(getIdToken: @escaping @Sendable () async throws -> String) async throws -> LatchwayAccount {
        try await acquireIdentity(intent: .signIn, generationID: nil, getIdToken: getIdToken)
    }

    /// Signs out this shared app locally, including native and React Native
    /// callers, without needing a current account handle. Concurrent calls join
    /// one cleanup. A secure-storage failure leaves the app fenced; call again
    /// to retry. Explicit signIn can then establish
    /// a fresh generation. This does not sign out your authentication provider
    /// or revoke the remote installation. Account-scoped installation keys and
    /// non-secret logout/key-retention markers remain for safe reuse.
    public func signOut() async throws {
        if let signOutTask { return try await signOutTask.value }
        // Establish intent synchronously, before any journal/cleanup actor hop.
        identityIntentEpoch = UUID()
        identityOperation = nil
        activationEpoch = nil
        verificationTask?.cancel()
        verificationTask = nil
        identityExpiryTask?.cancel()
        identityExpiryTask = nil
        identityState.clear()
        let target = generation
        target?.fenceSignOut()
        state = .retiring
        changed()
        let task = Task {
            defer { self.signOutTask = nil }
            try await self.finishSignOut(target: target)
        }
        signOutTask = task
        try await task.value
    }

    private func finishSignOut(target: LatchwayAccountGeneration?) async throws {
        await journal.fenceSignOut()
        if let target {
            // Generation cleanup cancels active operations before storage I/O.
            // Its deadline never abandons the background drain; retries join it.
            try await target.logout()
            // A previous timed-out waiter may have completed cleanup in the
            // background. Clear this retry's journal fence in that case too.
            try await journal.finishRetirement(target.id)
        } else if let entry = try await journal.entry() {
            try await journal.retire(entry.generation)
            try await journal.finishRetirement(entry.generation)
        } else {
            try await journal.recordEmptyLogout()
        }
        generation = nil
        persistedGenerationID = nil
        verifiedGenerationID = nil
        installationKey = nil
        attestation = nil
        state = .loggedOut
        changed()
    }

    /// Restores only an untouched app or an unretired matching account. A
    /// recorded logout requires explicit signIn, even if the auth SDK restores.
    public func restore(idToken: String) async throws -> LatchwayAccount {
        try await restore { idToken }
    }

    public func restore(getIdToken: @escaping @Sendable () async throws -> String) async throws -> LatchwayAccount {
        try await acquireIdentity(intent: .restore, generationID: nil, getIdToken: getIdToken)
    }

    public func currentAccount() throws -> LatchwayAccount? {
        guard registration.suppliedIdentity != nil else { throw LatchwayLifecycleError.configurationConflict }
        guard let generation, verifiedGenerationID == generation.id,
              state == .active || state == .refreshRequired else { return nil }
        return .init(app: self, generationID: generation.id)
    }

    func acquireIdentity(intent: LatchwayIdentityIntent, generationID: UUID?,
                         getIdToken: @escaping @Sendable () async throws -> String) async throws -> LatchwayAccount {
        let ticket = try await beginIdentity(intent: intent, generationID: generationID)
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let token = try await getIdToken()
                try Task.checkCancellation()
                return try await completeIdentity(ticketID: ticket, idToken: token)
            } catch {
                try? await cancelIdentity(ticketID: ticket)
                throw error
            }
        } onCancel: {
            Task { try? await self.cancelIdentity(ticketID: ticket) }
        }
    }

    /// Native operation ticket captured before a JS/native async token producer.
    /// This is public for platform bridges, not required in application code.
    public func claimIdentityBinding(_ bindingID: UUID) throws {
        guard registration.suppliedIdentity != nil, identityBindingID == nil || identityBindingID == bindingID else {
            throw LatchwayLifecycleError.configurationConflict
        }
        identityBindingID = bindingID
    }

    public func releaseIdentityBinding(_ bindingID: UUID) async {
        guard identityBindingID == bindingID else { return }
        identityBindingID = nil
        guard let pending = identityOperation, pending.bindingID == bindingID else { return }
        try? await cancelIdentity(ticketID: pending.id)
    }

    public func beginIdentity(intent: LatchwayIdentityIntent, generationID: UUID? = nil,
                              bindingID: UUID? = nil) async throws -> UUID {
        let supplied = identityState
        guard registration.suppliedIdentity != nil else { throw LatchwayLifecycleError.configurationConflict }
        guard state != .retiring, signOutTask == nil else { throw LatchwayLifecycleError.cleanupRequired }
        guard bindingID == nil || bindingID == identityBindingID else { throw LatchwayLifecycleError.configurationConflict }
        let intentEpoch = UUID()
        identityIntentEpoch = intentEpoch
        if intent == .update {
            guard let generationID, generationID == generation?.id else { throw LatchwayLifecycleError.loggedOut }
        }
        if intent == .restore {
            guard state != .loggedOut, try await journal.entry()?.state != .loggedOut else {
                throw LatchwayLifecycleError.loggedOut
            }
            guard identityIntentEpoch == intentEpoch, state != .loggedOut, state != .retiring else {
                throw LatchwayLifecycleError.loggedOut
            }
        }
        let operation = IdentityOperation(id: UUID(), intent: intent, generationID: verifiedGenerationID, bindingID: bindingID)
        identityOperation = operation
        supplied.suspend(operationID: operation.id)
        verificationTask?.cancel()
        verificationTask = nil
        identityExpiryTask?.cancel()
        await journal.beginIdentityOperation(operation.id)
        try requireIdentityTicket(operation.id)
        guard identityOperation?.id == operation.id else { throw LatchwayLifecycleError.accountChanged }
        if generation != nil { state = .refreshRequired; changed() }
        return operation.id
    }

    public func completeIdentity(ticketID: UUID, idToken: String,
                                 runtime: LatchwayClientRuntime = .iOS) async throws -> LatchwayAccount {
        guard let operation = identityOperation, operation.id == ticketID,
              let configuration = registration.suppliedIdentity else {
            throw LatchwayLifecycleError.accountChanged
        }
        try Task.checkCancellation()
        let supplied = identityState
        let candidate = try LatchwaySuppliedToken(idToken, configuration: configuration)
        let binding = try candidate.snapshot.binding(expectedIssuer: configuration.issuer, expectedTenant: configuration.tenantID)
        let accountScope = accountScope(binding: binding)
        let previous = try await journal.entry()
        try requireIdentityTicket(ticketID)
        if operation.intent == .restore, previous?.state == .loggedOut {
            throw LatchwayLifecycleError.loggedOut
        }
        if let previous, previous.state == .active, previous.account != accountScope {
            guard operation.intent == .signIn else { throw LatchwayLifecycleError.accountChanged }
            // Preserve this new intent while durably retiring only its predecessor.
            try await retireForReplacement(previous.generation, ticketID: ticketID)
            supplied.suspend(operationID: ticketID)
            try requireIdentityTicket(ticketID)
        }
        if operation.intent == .update {
            guard generation?.id == operation.generationID else { throw LatchwayLifecycleError.loggedOut }
        }
        if generation == nil {
            activationEpoch = ticketID
            _ = try await performActivation(ticketID, suppliedSnapshot: candidate.snapshot)
            try requireIdentityTicket(ticketID)
            activationEpoch = nil
        }
        guard let generation, let key = installationKey, let attestation else {
            throw LatchwayLifecycleError.identityUnavailable
        }
        let client = try await buildClient(generation: generation, installationKey: key, attestation: attestation,
                                 runtime: runtime, sdkVersion: LatchwayVersion.sdk, recoveryToken: idToken)
        do { try requireIdentityTicket(ticketID) }
        catch { await client.close(); throw error }
        let verifier = identityVerificationOverride
        let task = Task {
            if let verifier { return try await verifier(idToken) }
            return try await client.verifySuppliedIdentity(idToken: idToken)
        }
        verificationTask = task
        let verified: LatchwayVerifiedIdentityWire
        do { verified = try await task.value }
        catch { await client.close(); throw error }
        await client.close()
        try requireIdentityTicket(ticketID)
        guard self.generation?.id == generation.id, verified.identity.provider == configuration.providerID,
              verified.identity.issuer == configuration.issuer,
              verified.identity.subject == candidate.snapshot.subject,
              verified.identity.audience.contains(configuration.audience),
              verified.identity.expiresAt > Date(), verified.identity.verifiedAt <= Date().addingTimeInterval(300) else {
            throw LatchwayError.invalidServerResponse
        }
        try supplied.commit(candidate, expiresAt: verified.identity.expiresAt, operationID: ticketID)
        try requireIdentityTicket(ticketID)
        identityOperation = nil
        verificationTask = nil
        verifiedGenerationID = generation.id
        state = .active
        changed()
        let deadline = min(candidate.expiresAt, verified.identity.expiresAt)
        scheduleIdentityExpiry(generationID: generation.id, deadline: deadline)
        return .init(app: self, generationID: generation.id)
    }

    public func cancelIdentity(ticketID: UUID) async throws {
        guard let operation = identityOperation, operation.id == ticketID else { return }
        let canResumePublishedAccount = operation.generationID != nil && operation.generationID == verifiedGenerationID
            && operation.generationID == generation?.id
        let intentEpoch = identityIntentEpoch
        identityOperation = nil
        activationEpoch = nil
        verificationTask?.cancel()
        verificationTask = nil
        if !canResumePublishedAccount {
            try await signOut()
            return
        }
        await journal.cancelIdentityOperation(ticketID)
        guard identityIntentEpoch == intentEpoch, identityOperation == nil,
              state != .retiring, state != .loggedOut,
              generation?.id == operation.generationID else { return }
        if canResumePublishedAccount {
            let supplied = identityState
            do {
                supplied.resume(operationID: ticketID)
                let fresh = supplied.isFresh()
                guard identityOperation == nil, generation?.id == operation.generationID else { return }
                state = fresh ? .active : .refreshRequired
                if let generation, let deadline = supplied.expiration(), fresh {
                    scheduleIdentityExpiry(generationID: generation.id, deadline: deadline)
                }
                changed()
            }

        }
    }

    private func requireIdentityTicket(_ id: UUID) throws {
        try Task.checkCancellation()
        guard identityOperation?.id == id else { throw LatchwayLifecycleError.accountChanged }
    }

    private func retireForReplacement(_ id: UUID, ticketID: UUID) async throws {
        try await retireGeneration(id, preservingIdentityOperation: true)
        try requireIdentityTicket(ticketID)
    }

    private func expireIdentity(generationID: UUID, deadline: Date) async {
        guard generation?.id == generationID, identityOperation == nil, deadline <= Date(),
              !identityState.isFresh() else { return }
        state = .refreshRequired
        changed()
    }

    private func scheduleIdentityExpiry(generationID: UUID, deadline: Date) {
        identityExpiryTask?.cancel()
        identityExpiryTask = Task { [weak self] in
            let remaining = max(0, min(deadline.timeIntervalSinceNow, 31_536_000))
            do { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
            catch { return }
            await self?.expireIdentity(generationID: generationID, deadline: deadline)
        }
    }

    private func accountScope(binding: String) -> String {
        let identity = registration.suppliedIdentity!
        return LatchwayAppIdentity.digest(["supplied:\(identity.providerID):\(identity.audience)", identity.issuer, identity.tenantID ?? "",
            registration.identityProvider!, registration.attestationPolicyID!,
            registration.fallback == .disallow ? "hardware-required" : "software-allowed", binding])
    }

    init(registration: LatchwayAppRegistration,
         attestationFactory: @escaping LatchwayAccountAttestationFactory,
         lifecycleRecords: (any LatchwayLifecycleRecords)? = nil,
         prepareAccount: (@Sendable (String) async throws -> Void)? = nil,
         verifyIdentity: (@Sendable (String) async throws -> LatchwayVerifiedIdentityWire)? = nil,
         cleanupTimeoutNanoseconds: UInt64 = 30_000_000_000) throws {
        self.registration = registration
        self.attestationFactory = attestationFactory
        accountPreparationOverride = prepareAccount
        identityVerificationOverride = verifyIdentity
        self.cleanupTimeoutNanoseconds = cleanupTimeoutNanoseconds
        sharedRecords = LatchwayKeychainRecords(service: "dev.latchway.shared.v3.\(registration.scope)",
                                                   accessGroup: registration.rootGroup!)
        let componentKeyIndex = LatchwaySharedComponentKeyIndex(records: sharedRecords)
        keyRetention = LatchwayAccountKeyRetention(records: LatchwayKeyRetentionRecords(records: sharedRecords)) { scope in
            try componentKeyIndex.evict(accountScope: scope)
            let store = LatchwayKeychainStore(service: "dev.latchway.shared.v3.account.\(scope)",
                                              accessGroup: registration.rootGroup!)
            try await LatchwayInstallationKeyManager(softwareFallbackPolicy: registration.fallback!,
                store: store, preferSecureEnclave: true).reset()
            // App Attest has no remote key-deletion operation. Reset only this
            // inactive account's local key reference/registration metadata.
            try await attestationFactory(scope).reset()
        }
        let records: any LatchwayLifecycleRecords = lifecycleRecords ?? LatchwayKeychainLifecycleRecords(records:
            LatchwayKeychainRecords(service: "dev.latchway.shared.v3.\(registration.scope)",
                                   accessGroup: registration.rootGroup!))
        journal = LatchwayAppSessionJournal(records: records, componentKeyIndex: componentKeyIndex)
        if let encoded = try records.read() {
            let previous = try JSONDecoder().decode(LatchwayAppSessionJournal.Entry.self, from: encoded)
            persistedGenerationID = previous.generation
            state = previous.state == .retiring ? .retiring : previous.state == .loggedOut ? .loggedOut : .inactive
        }
    }

    public static func configure(_ options: LatchwayAppOptions, name: String = LatchwayAppRegistry.defaultName,
                                 attestationFactory: LatchwayAccountAttestationFactory? = nil) async throws -> LatchwayApp {
        try await LatchwayAppRegistry.shared.configure(options, name: name,
                                                       attestationFactory: attestationFactory)
    }

    public static func getApp(_ name: String = LatchwayAppRegistry.defaultName) async throws -> LatchwayApp {
        try await LatchwayAppRegistry.shared.getApp(name)
    }

    public func snapshot() -> LatchwayAppSnapshot {
        let publicGeneration = state != .retiring
            ? verifiedGenerationID : generation?.id ?? persistedGenerationID
        return .init(appInstanceID: instanceID,
              generationID: publicGeneration, revision: revision, state: state)
    }

    /// The first event is an atomic snapshot, so a bridge cannot lose a logout
    /// between fetching state and subscribing. Revisions order later events.
    public func snapshots() -> AsyncStream<LatchwayAppSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<LatchwayAppSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.yield(snapshot())
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return stream
    }

    private func performActivation(_ epoch: UUID, suppliedSnapshot: LatchwayIdentitySnapshot) async throws -> UUID {
        guard state != .retiring else { throw LatchwayLifecycleError.cleanupRequired }
        guard activationEpoch == epoch else { throw LatchwayLifecycleError.loggedOut }
        guard let identity = registration.suppliedIdentity else { throw LatchwayLifecycleError.identityUnavailable }
        let current = suppliedSnapshot
        let binding = try current.binding(expectedIssuer: identity.issuer, expectedTenant: identity.tenantID)
        guard activationEpoch == epoch else { throw LatchwayLifecycleError.loggedOut }
        if let generation {
            // This validates the current account even when a session is cached.
            guard activationEpoch == epoch else { throw LatchwayLifecycleError.loggedOut }
            return generation.id
        }
        let accountScope = accountScope(binding: binding)
        try await journal.checkActivation(account: accountScope)
        let scope = LatchwayAppIdentity.digest([registration.scope, registration.rootGroup!, accountScope])
        if let accountPreparationOverride { try await accountPreparationOverride(scope) }
        else { try await keyRetention.prepare(scope) }
        guard activationEpoch == epoch else { throw LatchwayLifecycleError.loggedOut }
        let entry = try await journal.activate(account: accountScope, identityTicket: epoch)
        guard activationEpoch == epoch else {
            if let current = try await journal.entry(), current.generation == entry.generation, current.state == .active {
                try await journal.retire(entry.generation)
                try await journal.finishRetirement(entry.generation)
            }
            throw LatchwayLifecycleError.cleanupRequired
        }
        let keyStore = LatchwayKeychainStore(service: "dev.latchway.shared.v3.account.\(scope)", accessGroup: registration.rootGroup!)
        let key = LatchwayInstallationKeyManager(softwareFallbackPolicy: registration.fallback!, store: keyStore,
                                                preferSecureEnclave: true)
        let provider = attestationFactory(scope)
        let journal = self.journal
        generation = LatchwayAccountGeneration(entry: entry, scope: scope, issuer: identity.issuer,
                                               tenant: identity.tenantID, identityState: identityState, journal: journal,
                                               accountBinding: binding,
                                               cleanupTimeoutNanoseconds: cleanupTimeoutNanoseconds,
                                               onIdentityLoss: { [weak self] in
            try? await self?.logout(generationID: entry.generation)
        },
                                               cleanup: {
            try await journal.retireComponents(entry.generation)
            let fingerprint = LatchwayProcessScopeIdentity.sharedFingerprint(scope: scope, generation: entry.generation)
            let coordinator = LatchwayProcessScopeCoordinatorPool.shared.root(
                identity: LatchwayProcessScopeIdentity.sharedRoot(scope: scope, generation: entry.generation),
                configurationFingerprint: fingerprint)
            let permit = try await coordinator.acquire(configurationFingerprint: fingerprint)
            await coordinator.invalidate(terminal: true, for: permit)
            await coordinator.release(permit)
        })
        installationKey = key
        attestation = provider
        persistedGenerationID = entry.generation
        state = .refreshRequired
        changed()
        return entry.generation
    }

    public func makeClient(runtime: LatchwayClientRuntime = .iOS,
                           sdkVersion: String = LatchwayVersion.sdk,
                           generationID: UUID? = nil) async throws -> LatchwayClient {
        if let generationID, generationID != generation?.id { throw LatchwayLifecycleError.loggedOut }
        guard let generation, let installationKey, let attestation, state == .active else {
            throw state == .refreshRequired ? LatchwayLifecycleError.identityRefreshRequired : LatchwayLifecycleError.loggedOut
        }
        _ = try await generation.identityToken()
        guard self.generation?.id == generation.id, state == .active, identityOperation == nil else {
            throw LatchwayLifecycleError.identityRefreshRequired
        }
        let client = try await buildClient(generation: generation, installationKey: installationKey, attestation: attestation,
                           runtime: runtime, sdkVersion: sdkVersion)
        guard self.generation?.id == generation.id, state == .active, identityOperation == nil else {
            await client.close()
            throw LatchwayLifecycleError.identityRefreshRequired
        }
        return client
    }

    private func buildClient(generation: LatchwayAccountGeneration, installationKey: any LatchwayInstallationKey,
                             attestation: any LatchwayAttestationProvider, runtime: LatchwayClientRuntime,
                             sdkVersion: String, recoveryToken: String? = nil) async throws -> LatchwayClient {
        var configuration = LatchwayConfiguration(baseURL: registration.baseURL, applicationID: registration.applicationID,
            environment: registration.environment, rootKeychainAccessGroup: registration.rootGroup!,
            identityProvider: registration.identityProvider!, clientRuntime: runtime, clientSDKVersion: sdkVersion,
            softwareKeyFallbackPolicy: registration.fallback!)
        configuration.accountGeneration = generation
        configuration.sharedComponentAccount = LatchwayComponentAccount(generationID: generation.id,
            appScope: registration.scope, accountScope: generation.storageScope)
        configuration.sharedComponentGroups = componentKeychainAccessGroups
        configuration.accountLogout = { try await self.logout(generationID: generation.id) }
        let transport = LatchwayGenerationTransport(generation: generation,
            base: LatchwayURLSessionTransport(session: LatchwayURLSessionFactory.make()), identityRecovery: recoveryToken != nil)
        let tokenProvider: any LatchwayIdentityTokenProvider
        if let recoveryToken { tokenProvider = LatchwayOneShotTokenProvider(token: recoveryToken) }
        else { tokenProvider = generation }
        let client = LatchwayClient(configuration: configuration, identityTokenProvider: tokenProvider,
            attestationProvider: attestation, installationKey: installationKey,
            sessionStorage: LatchwayGenerationSessionStorage(journal: journal, generation: generation.id),
            transport: transport, clock: LatchwaySystemClock(), rootKeychainPreflight: {},
            processScopeNamespace: LatchwayProcessScopeIdentity.productionNamespace)
        try await generation.registerClientCleanup(for: client) { [weak client] in await client?.clearAccountCredentials() }
        return client
    }

    /// Explicitly targets a captured generation; a delayed sign-out callback
    /// cannot retire a subsequent account or a subsequent login of the same UID.
    public func logout(generationID: UUID) async throws {
        guard generationID == generation?.id ||
                (generationID == persistedGenerationID && state != .loggedOut) else { return }
        try await signOut()
    }

    private func retireGeneration(_ generationID: UUID, preservingIdentityOperation: Bool) async throws {
        if generationID == generation?.id || generationID == persistedGenerationID {
            identityIntentEpoch = UUID()
            state = .retiring
            if !preservingIdentityOperation { identityOperation = nil }
            verificationTask?.cancel()
            verificationTask = nil
            identityState.clear()
        }
        guard let generation, generation.id == generationID else {
            // Recover an interrupted retirement without asking the auth owner.
            if let entry = try await journal.entry(), entry.generation == generationID {
                activationEpoch = nil
                state = .retiring
                changed()
                try await journal.retire(generationID)
                try await journal.retireComponents(generationID)
                try await journal.finishRetirement(generationID)
                persistedGenerationID = nil
                verifiedGenerationID = nil
                state = .loggedOut
                changed()
            }
            return
        }
        activationEpoch = nil
        state = .retiring
        changed()
        try await generation.logout()
        guard self.generation?.id == generationID else { return }
        self.generation = nil
        persistedGenerationID = nil
        verifiedGenerationID = nil
        installationKey = nil
        attestation = nil
        state = .loggedOut
        changed()
    }

    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    private func changed() {
        revision &+= 1
        let current = snapshot()
        for observer in observers.values { observer.yield(current) }
    }
}

struct LatchwayGenerationTransport: LatchwayHTTPTransport {
    let generation: LatchwayAccountGeneration
    let base: any LatchwayHTTPTransport
    var identityRecovery = false

    func send(_ request: URLRequest) async throws -> LatchwayHTTPResponse {
        if identityRecovery { try await generation.check() }
        else { _ = try await generation.identityToken() }
        let task = Task { try await base.send(request) }
        let cancellation: UUID
        do { cancellation = try await generation.registerCancellation { task.cancel() } }
        catch { task.cancel(); throw error }
        do {
            let response = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            await generation.unregisterCancellation(cancellation)
            if identityRecovery { try await generation.check() }
            else { _ = try await generation.identityToken() }
            return response
        } catch {
            await generation.unregisterCancellation(cancellation)
            throw error
        }
    }
}
