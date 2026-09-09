import Foundation

public struct LatchwayIdentityAuthorityReference: Sendable, Equatable {
    public let name: String
    public let issuer: String
    public let tenant: String?
    public init(name: String, issuer: String, tenant: String? = nil) {
        self.name = name
        self.issuer = issuer
        self.tenant = tenant
    }
}

/// Native-only cleanup for legacy custom persistence that the SDK cannot
/// inventory. Use a stable ID and an idempotent, offline operation. Throw on
/// incomplete cleanup; the migration journal remains pending and activation is
/// blocked. Do not call Latchway authorization from this operation.
public struct LatchwayLegacyMigration: Sendable {
    public let id: String
    let cleanup: @Sendable () async throws -> Void
    public init(id: String, cleanup: @escaping @Sendable () async throws -> Void) {
        self.id = id
        self.cleanup = cleanup
    }
}

/// Omitted settings inherit an existing registration. On first registration,
/// rootKeychainAccessGroup, identity and an authority implementation are required.
public struct LatchwayAppOptions: Sendable {
    public let baseURL: URL
    public let applicationID: String
    public let environment: String
    public var rootKeychainAccessGroup: String?
    public var identity: LatchwayIdentityAuthorityReference?
    public var suppliedIdentity: LatchwaySuppliedIdentityConfiguration?
    public var identityProvider: String?
    public var attestationPolicyID: String?
    public var softwareKeyFallbackPolicy: LatchwaySoftwareKeyFallbackPolicy?
    public var exposeToReactNative: Bool?
    public var componentKeychainAccessGroups: [String]?
    public var legacySharedKeychainAccessGroups: [String]?
    public var legacyComponents: [LatchwayComponentConfiguration]?
    public var legacyAttestationNamespaces: [String]?
    public var legacyMigration: LatchwayLegacyMigration?

    public init(baseURL: URL, applicationID: String, environment: String,
                rootKeychainAccessGroup: String? = nil,
                identity: LatchwayIdentityAuthorityReference? = nil,
                suppliedIdentity: LatchwaySuppliedIdentityConfiguration? = nil,
                identityProvider: String? = nil,
                attestationPolicyID: String? = nil,
                softwareKeyFallbackPolicy: LatchwaySoftwareKeyFallbackPolicy? = nil,
                exposeToReactNative: Bool? = nil,
                componentKeychainAccessGroups: [String]? = nil,
                legacySharedKeychainAccessGroups: [String]? = nil,
                legacyComponents: [LatchwayComponentConfiguration]? = nil,
                legacyAttestationNamespaces: [String]? = nil,
                legacyMigration: LatchwayLegacyMigration? = nil) {
        self.baseURL = baseURL
        self.applicationID = applicationID
        self.environment = environment
        self.rootKeychainAccessGroup = rootKeychainAccessGroup
        self.identity = identity
        self.suppliedIdentity = suppliedIdentity
        self.identityProvider = identityProvider
        self.attestationPolicyID = attestationPolicyID
        self.softwareKeyFallbackPolicy = softwareKeyFallbackPolicy
        self.exposeToReactNative = exposeToReactNative
        self.componentKeychainAccessGroups = componentKeychainAccessGroups
        self.legacySharedKeychainAccessGroups = legacySharedKeychainAccessGroups
        self.legacyComponents = legacyComponents
        self.legacyAttestationNamespaces = legacyAttestationNamespaces
        self.legacyMigration = legacyMigration
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
        authority: (any LatchwayIdentityAuthority)? = nil,
        attestationFactory: LatchwayAccountAttestationFactory? = nil,
        authorityInstanceID: UUID? = nil,
        fromReactNative: Bool = false
    ) throws -> LatchwayApp {
        let resolved = try LatchwayAppRegistration(options)
        guard !name.isEmpty, name.utf8.count <= 128 else { throw LatchwayLifecycleError.configurationConflict }
        if let existing = names[name] {
            try existing.registration.compare(resolved, hasAuthority: authority != nil, fromReactNative: fromReactNative)
            return existing
        }
        if let existing = scopes[resolved.scope] {
            try existing.registration.compare(resolved, hasAuthority: authority != nil, fromReactNative: fromReactNative)
            names[name] = existing
            return existing
        }
        guard let identity = resolved.identity, !identity.name.isEmpty, !identity.issuer.isEmpty,
              let attestationFactory, let root = resolved.rootGroup else {
            throw LatchwayLifecycleError.identityAuthorityRequired
        }
        let supplied = resolved.suppliedIdentity.map { _ in LatchwaySuppliedIdentityAuthority() }
        let owner: (any LatchwayIdentityAuthority)?
        if let supplied { owner = supplied }
        else { owner = authority }
        guard !(supplied != nil && authority != nil), let owner else {
            throw LatchwayLifecycleError.identityAuthorityRequired
        }
        if fromReactNative, resolved.expose == false { throw LatchwayLifecycleError.configurationConflict }
        try LatchwayRootKeychainPreflight.verifySignedDefaultAccessGroup(root,
            legacySharedKeychainAccessGroups: resolved.legacyGroups ?? [])
        try LatchwayRootKeychainPreflight.validateAccessGroups(rootKeychainAccessGroup: root,
            legacySharedKeychainAccessGroups: resolved.componentGroups ?? [])
        let registration = resolved.effective()
        let app = try LatchwayApp(registration: registration, authority: owner,
                              attestationFactory: attestationFactory, authorityInstanceID: authorityInstanceID ?? UUID())
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

    func requireLegacyScopeUnregistered(_ configuration: LatchwayConfiguration) throws {
        let url = try LatchwayAppIdentity.canonicalURL(configuration.baseURL)
        let scope = LatchwayAppIdentity.digest([url.absoluteString, configuration.applicationID, configuration.environment])
        guard scopes[scope] == nil else { throw LatchwayLifecycleError.configurationConflict }
        guard configuration.checksPersistentLegacyFence else { return }
        let records = LatchwayKeychainRecords(service: "dev.latchway.shared.v3.\(scope)",
            accessGroup: configuration.rootKeychainAccessGroup)
        if try records.read(account: "legacy-retirement-v3") != nil {
            throw LatchwayLifecycleError.configurationConflict
        }
        let legacy = LatchwayKeychainRecords(service: LatchwayKeychainNamespace.service(
            applicationID: configuration.applicationID, environment: configuration.environment,
            clientRuntime: configuration.clientRuntime), accessGroup: configuration.rootKeychainAccessGroup)
        if try legacy.read(account: "shared-native-retirement-v3") != nil {
            throw LatchwayLifecycleError.configurationConflict
        }
    }
}

struct LatchwayAppRegistration: Sendable {
    let baseURL: URL
    let applicationID: String
    let environment: String
    var rootGroup: String?
    let identity: LatchwayIdentityAuthorityReference?
    let suppliedIdentity: LatchwaySuppliedIdentityConfiguration?
    var identityProvider: String?
    var attestationPolicyID: String?
    var fallback: LatchwaySoftwareKeyFallbackPolicy?
    var expose: Bool?
    var componentGroups: [String]?
    var legacyGroups: [String]?
    var legacyComponents: [LatchwayComponentConfiguration]?
    var legacyAttestationNamespaces: [String]?
    var legacyMigration: LatchwayLegacyMigration?
    var legacyInventoryDeclared = false
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
        guard options.identity == nil || suppliedIdentity == nil,
              options.identityProvider == nil || suppliedIdentity == nil || options.identityProvider == suppliedIdentity?.providerID else {
            throw LatchwayLifecycleError.configurationConflict
        }
        identity = suppliedIdentity?.reference ?? options.identity
        identityProvider = options.identityProvider ?? suppliedIdentity?.providerID
        attestationPolicyID = options.attestationPolicyID
        fallback = options.softwareKeyFallbackPolicy
        expose = options.exposeToReactNative
        componentGroups = options.componentKeychainAccessGroups?.sorted()
        legacyGroups = options.legacySharedKeychainAccessGroups?.sorted()
        legacyComponents = options.legacyComponents
        legacyInventoryDeclared = options.legacyComponents != nil || options.legacyMigration != nil
        legacyAttestationNamespaces = options.legacyAttestationNamespaces?.sorted()
        legacyMigration = options.legacyMigration
        guard (legacyGroups?.count ?? 0) <= 32, (componentGroups?.count ?? 0) <= 256,
              (legacyComponents?.count ?? 0) <= 256,
              (legacyAttestationNamespaces?.count ?? 0) <= 128,
              legacyAttestationNamespaces?.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 255 &&
                  $0.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil }) ?? true
        else { throw LatchwayLifecycleError.configurationConflict }
        try legacyComponents?.forEach { try $0.validateForContainingApplication() }
        if let legacyMigration {
            guard !legacyMigration.id.isEmpty, legacyMigration.id.utf8.count <= 128 else {
                throw LatchwayLifecycleError.configurationConflict
            }
        }
    }

    func effective() -> Self {
        var copy = self
        copy.identityProvider = identityProvider ?? "firebase"
        copy.attestationPolicyID = attestationPolicyID ?? "app-attest"
        copy.fallback = fallback ?? .disallow
        copy.expose = expose ?? true
        copy.componentGroups = componentGroups ?? []
        copy.legacyGroups = legacyGroups ?? []
        copy.legacyComponents = legacyComponents ?? []
        copy.legacyAttestationNamespaces = legacyAttestationNamespaces ?? []
        return copy
    }

    func compare(_ supplied: Self, hasAuthority: Bool, fromReactNative: Bool) throws {
        guard scope == supplied.scope,
              supplied.rootGroup == nil || supplied.rootGroup == rootGroup,
              supplied.identity == nil || supplied.identity == identity,
              supplied.suppliedIdentity == nil || supplied.suppliedIdentity == suppliedIdentity,
              supplied.identity == nil || (supplied.suppliedIdentity != nil) == (suppliedIdentity != nil),
              !hasAuthority || suppliedIdentity == nil,
              !hasAuthority || supplied.identity == identity,
              supplied.identityProvider == nil || supplied.identityProvider == identityProvider,
              supplied.attestationPolicyID == nil || supplied.attestationPolicyID == attestationPolicyID,
              supplied.fallback == nil || supplied.fallback == fallback,
              supplied.expose == nil || supplied.expose == expose,
              supplied.componentGroups == nil || supplied.componentGroups == componentGroups,
              supplied.legacyGroups == nil || supplied.legacyGroups == legacyGroups,
              supplied.legacyComponents == nil || Set(supplied.legacyComponents!) == Set(legacyComponents ?? []),
              supplied.legacyAttestationNamespaces == nil || supplied.legacyAttestationNamespaces == legacyAttestationNamespaces,
              supplied.legacyMigration == nil || supplied.legacyMigration?.id == legacyMigration?.id,
              !supplied.legacyInventoryDeclared || legacyInventoryDeclared,
              !fromReactNative || expose == true else {
            throw LatchwayLifecycleError.configurationConflict
        }
        // A redundant implementation accompanying the same explicit authority
        // reference is deliberately unused. Never replace the registered owner.
    }

    func requireLegacyInventory(hasUnboundRoot: Bool, hasRegistry: Bool) throws {
        guard !hasUnboundRoot || hasRegistry || legacyInventoryDeclared else {
            throw LatchwayError.rootKeychainMigrationRequired
        }
    }
}

/// Process-wide app backend. Configuration never activates an account. Native
/// and React Native clients are leases on its account-bound session generation.
public actor LatchwayApp {
    public nonisolated let instanceID = UUID()
    public private(set) var authorityInstanceID: UUID
    nonisolated let registration: LatchwayAppRegistration
    public nonisolated var baseURL: URL { registration.baseURL }
    public nonisolated var applicationID: String { registration.applicationID }
    public nonisolated var environment: String { registration.environment }
    public nonisolated var identityMode: String { registration.suppliedIdentity == nil ? "authority" : "supplied" }
    /// The native owner's approved component groups, not root credentials or
    /// inferred JS defaults. Actual entitlement access is enforced by Keychain.
    public nonisolated var componentKeychainAccessGroups: [String] { registration.componentGroups ?? [] }
    private var authority: any LatchwayIdentityAuthority
    private var transferringAuthority = false
    private let attestationFactory: LatchwayAccountAttestationFactory
    private let journal: LatchwayAppSessionJournal
    private let migrationRecords: LatchwayKeychainRecords
    private let keyRetention: LatchwayAccountKeyRetention
    private var generation: LatchwayAccountGeneration?
    private var persistedGenerationID: UUID?
    private var installationKey: (any LatchwayInstallationKey)?
    private var attestation: (any LatchwayAttestationProvider)?
    private var revision: UInt64 = 0
    private var state: LatchwayAppSnapshot.State = .inactive
    private var activationTask: Task<UUID, Error>?
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
    private let migrationOverride: (@Sendable () async throws -> Void)?
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
    /// to retry. Explicit signIn (or authority-mode activate) can then establish
    /// a fresh generation. This does not sign out your authentication provider
    /// or revoke the remote installation. Account-scoped installation keys and
    /// non-secret logout/key-retention markers remain for safe reuse.
    public func signOut() async throws {
        if let signOutTask { return try await signOutTask.value }
        // Establish intent synchronously, before any journal/cleanup actor hop.
        identityIntentEpoch = UUID()
        identityOperation = nil
        activationEpoch = nil
        activationTask?.cancel()
        activationTask = nil
        verificationTask?.cancel()
        verificationTask = nil
        identityExpiryTask?.cancel()
        identityExpiryTask = nil
        (authority as? LatchwaySuppliedIdentityAuthority)?.clear()
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
        guard let supplied = authority as? LatchwaySuppliedIdentityAuthority,
              registration.suppliedIdentity != nil else { throw LatchwayLifecycleError.configurationConflict }
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
              let configuration = registration.suppliedIdentity,
              let supplied = authority as? LatchwaySuppliedIdentityAuthority else {
            throw LatchwayLifecycleError.accountChanged
        }
        try Task.checkCancellation()
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
            if let supplied = authority as? LatchwaySuppliedIdentityAuthority {
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
              let supplied = authority as? LatchwaySuppliedIdentityAuthority, !supplied.isFresh() else { return }
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
        let identity = registration.identity!
        return LatchwayAppIdentity.digest([identity.name, identity.issuer, identity.tenant ?? "",
            registration.identityProvider!, registration.attestationPolicyID!,
            registration.fallback == .disallow ? "hardware-required" : "software-allowed", binding])
    }

    init(registration: LatchwayAppRegistration, authority: any LatchwayIdentityAuthority,
         attestationFactory: @escaping LatchwayAccountAttestationFactory, authorityInstanceID: UUID = UUID(),
         lifecycleRecords: (any LatchwayLifecycleRecords)? = nil,
         migration: (@Sendable () async throws -> Void)? = nil,
         prepareAccount: (@Sendable (String) async throws -> Void)? = nil,
         verifyIdentity: (@Sendable (String) async throws -> LatchwayVerifiedIdentityWire)? = nil,
         cleanupTimeoutNanoseconds: UInt64 = 30_000_000_000) throws {
        self.authorityInstanceID = authorityInstanceID
        self.registration = registration
        self.authority = authority
        self.attestationFactory = attestationFactory
        migrationOverride = migration
        accountPreparationOverride = prepareAccount
        identityVerificationOverride = verifyIdentity
        self.cleanupTimeoutNanoseconds = cleanupTimeoutNanoseconds
        migrationRecords = LatchwayKeychainRecords(service: "dev.latchway.shared.v3.\(registration.scope)",
                                                   accessGroup: registration.rootGroup!)
        let componentKeyIndex = LatchwaySharedComponentKeyIndex(records: migrationRecords)
        keyRetention = LatchwayAccountKeyRetention(records: LatchwayKeyRetentionRecords(records: migrationRecords)) { scope in
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
                                 authority: (any LatchwayIdentityAuthority)? = nil,
                                 attestationFactory: LatchwayAccountAttestationFactory? = nil) async throws -> LatchwayApp {
        try await LatchwayAppRegistry.shared.configure(options, name: name, authority: authority,
                                                       attestationFactory: attestationFactory)
    }

    public static func getApp(_ name: String = LatchwayAppRegistry.defaultName) async throws -> LatchwayApp {
        try await LatchwayAppRegistry.shared.getApp(name)
    }

    public func snapshot() -> LatchwayAppSnapshot {
        let publicGeneration = registration.suppliedIdentity != nil && state != .retiring
            ? verifiedGenerationID : generation?.id ?? persistedGenerationID
        return .init(appInstanceID: instanceID, authorityInstanceID: authorityInstanceID,
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

    /// Only the registered authentication owner should call this after login.
    /// A new handle is required after logout, including for the same user.
    @discardableResult
    public func activate() async throws -> UUID {
        guard registration.suppliedIdentity == nil else { throw LatchwayLifecycleError.identityAuthorityRequired }
        guard !transferringAuthority, state != .retiring, signOutTask == nil else { throw LatchwayLifecycleError.cleanupRequired }
        if let activationTask { return try await activationTask.value }
        let epoch = UUID()
        activationEpoch = epoch
        let task = Task { try await self.performActivation(epoch) }
        activationTask = task
        defer { if activationEpoch == epoch { activationTask = nil; activationEpoch = nil } }
        return try await task.value
    }

    private func performActivation(_ epoch: UUID, suppliedSnapshot: LatchwayIdentitySnapshot? = nil) async throws -> UUID {
        guard state != .retiring else { throw LatchwayLifecycleError.cleanupRequired }
        if suppliedSnapshot == nil {
            await journal.beginIdentityOperation(epoch)
            guard activationEpoch == epoch else { throw LatchwayLifecycleError.loggedOut }
        }
        try await migrateLegacyRoots()
        guard activationEpoch == epoch else { throw LatchwayLifecycleError.loggedOut }
        guard let identity = registration.identity else { throw LatchwayLifecycleError.identityUnavailable }
        let currentValue: LatchwayIdentitySnapshot?
        if let suppliedSnapshot { currentValue = suppliedSnapshot }
        else { currentValue = try await authority.identitySnapshot() }
        guard let current = currentValue else { throw LatchwayLifecycleError.identityUnavailable }
        let binding = try current.binding(expectedIssuer: identity.issuer, expectedTenant: identity.tenant)
        guard activationEpoch == epoch else { throw LatchwayLifecycleError.loggedOut }
        if let generation {
            // This validates the current account even when a session is cached.
            if suppliedSnapshot == nil { _ = try await generation.identityToken() }
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
                                               tenant: identity.tenant, authority: authority, journal: journal,
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
        state = suppliedSnapshot == nil ? .active : .refreshRequired
        changed()
        return entry.generation
    }

    public func makeClient(runtime: LatchwayClientRuntime = .iOS,
                           sdkVersion: String = LatchwayVersion.sdk,
                           generationID: UUID? = nil) async throws -> LatchwayClient {
        if let generationID, generationID != generation?.id { throw LatchwayLifecycleError.loggedOut }
        guard !transferringAuthority, let generation, let installationKey, let attestation, state == .active else {
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
            (authority as? LatchwaySuppliedIdentityAuthority)?.clear()
        }
        guard let generation, generation.id == generationID else {
            // Recover an interrupted retirement without asking the auth owner.
            if let entry = try await journal.entry(), entry.generation == generationID {
                activationEpoch = nil
                activationTask?.cancel()
                activationTask = nil
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
        activationTask?.cancel()
        activationTask = nil
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

    /// Explicit compare-and-swap ownership transfer, including JS reloads.
    /// Retires the old account offline before replacing its identity provider.
    /// This never activates the replacement. An activation already in progress
    /// must finish (or be retired) before retrying; configure never transfers.
    public func transferIdentityAuthority(
        to replacement: any LatchwayIdentityAuthority,
        reference: LatchwayIdentityAuthorityReference,
        expectedAuthorityInstanceID: UUID,
        replacementInstanceID: UUID = UUID()
    ) async throws {
        guard reference == registration.identity, expectedAuthorityInstanceID == authorityInstanceID,
              registration.suppliedIdentity == nil,
              replacementInstanceID != authorityInstanceID, !transferringAuthority,
              activationTask == nil else { throw LatchwayLifecycleError.configurationConflict }
        transferringAuthority = true
        defer { transferringAuthority = false }
        if let target = generation?.id ?? persistedGenerationID {
            try await logout(generationID: target)
        }
        guard state != .retiring else { throw LatchwayLifecycleError.cleanupRequired }
        authority = replacement
        authorityInstanceID = replacementInstanceID
        changed()
    }

    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    private func migrateLegacyRoots() async throws {
        if let migrationOverride { try await migrationOverride(); return }
        let componentCoordinates = (registration.legacyComponents ?? []).map {
            LatchwayAppIdentity.digest([$0.definitionID, $0.kind, $0.keychainAccessGroup])
        }.sorted()
        let inventory = LatchwayAppIdentity.digest(["inventory-v1", registration.rootGroup!]
            + (registration.legacyGroups ?? []) + componentCoordinates
            + (registration.legacyAttestationNamespaces ?? []) + [registration.legacyMigration?.id ?? ""])
        let completed = Data("complete:\(inventory)".utf8)
        if try migrationRecords.read(account: "legacy-retirement-v3") == completed { return }
        // A crash at any following step retries this exact scoped cleanup.
        // Never import/relabel a legacy refresh chain or DPoP/App Attest key.
        try migrationRecords.write(Data("pending:\(inventory)".utf8), account: "legacy-retirement-v3")
        for runtime in LatchwayClientRuntime.allCases {
            let configuration = LatchwayConfiguration(baseURL: registration.baseURL,
                applicationID: registration.applicationID, environment: registration.environment,
                rootKeychainAccessGroup: registration.rootGroup!, clientRuntime: runtime,
                softwareKeyFallbackPolicy: registration.fallback!)
            let fingerprint = LatchwayProcessScopeIdentity.rootFingerprint(configuration: configuration)
            let coordinator = LatchwayProcessScopeCoordinatorPool.shared.root(
                identity: LatchwayProcessScopeIdentity.root(configuration: configuration,
                    namespace: LatchwayProcessScopeIdentity.productionNamespace), configurationFingerprint: fingerprint)
            try await coordinator.retireForMigrationAndDrain()
            let retirer = LatchwayKeychainComponentStateRetirer(configuration: configuration)
            let service = LatchwayKeychainNamespace.service(applicationID: registration.applicationID,
                environment: registration.environment, clientRuntime: runtime)
            for group in [registration.rootGroup!] + (registration.legacyGroups ?? []) {
                // The root was verified before registration. This inventory
                // reads only exact legacy SDK coordinates, not arbitrary group
                // contents, and never adopts their credentials.
                let registry = LatchwayKeychainComponentRegistry(
                    store: LatchwayKeychainStore(service: service, accessGroup: group),
                    lockIdentity: "\(service)|\(group)")
                let records = LatchwayKeychainRecords(service: service, accessGroup: group)
                try records.write(Data("retired".utf8), account: "shared-native-retirement-v3")
                var hasUnboundRoot = false
                for account in ["session", "installation-key", "installation-key-kind"] {
                    if try records.read(account: account) != nil { hasUnboundRoot = true }
                }
                let hasRegistry = try records.read(account: LatchwayKeychainComponentRegistry.account) != nil
                // A pre-registry root may have unknown component stores. An
                // explicit empty inventory means none; omission does not.
                try registration.requireLegacyInventory(hasUnboundRoot: hasUnboundRoot, hasRegistry: hasRegistry)
                try await LatchwayComponentFamilyRetirement.retireAll(registry: registry,
                    including: registration.legacyComponents ?? [], retire: { component in
                        try LatchwayLegacyComponentFence(configuration: configuration, component: component).retire()
                        try await retirer.retire(component)
                    })
                for account in ["session", "installation-key", "installation-key-kind"] {
                    try records.delete(account: account)
                }
                let namespaces = ["\(runtime.platformIdentifier).\(registration.applicationID).\(registration.environment)"]
                    + (registration.legacyAttestationNamespaces ?? [])
                for namespace in Set(namespaces) {
                    try LatchwayKeychainRecords(service: "dev.latchway.sdk.app-attest.\(namespace)",
                        accessGroup: group).delete(account: "app-attest-state")
                }
            }
            try await attestationFactory("\(runtime.platformIdentifier).\(registration.applicationID).\(registration.environment)").reset()
        }
        try await registration.legacyMigration?.cleanup()
        try migrationRecords.write(completed, account: "legacy-retirement-v3")
    }

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
