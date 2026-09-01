@preconcurrency import Foundation

public actor LatchwayClient {
    private let configuration: LatchwayConfiguration
    private let identityTokenProvider: any LatchwayIdentityTokenProvider
    private let attestationProvider: any LatchwayAttestationProvider
    private let installationKey: any LatchwayInstallationKey
    private let sessionStorage: any LatchwaySessionStorage
    private let componentRegistry: any LatchwayComponentRegistry
    private let componentStateRetirer: any LatchwayComponentStateRetiring
    private let transport: any LatchwayHTTPTransport
    private let clock: any LatchwayClock
    private let proofFactory: LatchwayDPoPProofFactory
    private let controlPlane: LatchwayControlPlane
    private let rootKeychainPreflight: @Sendable () throws -> Void

    private var session: RuntimeSession?
    private var establishmentTask: Task<RuntimeSession, Error>?
    private var refreshTask: Task<RuntimeSession, Error>?
    private var state: LatchwayDiagnostics.SessionState = .absent
    private var lastRequestID: String?
    private var lastErrorCode: String?
    private var serverVersion: String?
    private var terminalError: LatchwayError?
    private var rootKeychainPreflightComplete = false

    public init(
        configuration: LatchwayConfiguration,
        identityTokenProvider: any LatchwayIdentityTokenProvider
    ) {
        let key = LatchwayInstallationKeyManager(
            applicationID: configuration.applicationID,
            environment: configuration.environment,
            rootKeychainAccessGroup: configuration.rootKeychainAccessGroup,
            legacySharedKeychainAccessGroups: configuration.legacySharedKeychainAccessGroups,
            clientRuntime: configuration.clientRuntime,
            softwareFallbackPolicy: configuration.softwareKeyFallbackPolicy
        )
        let storage = LatchwayKeychainSessionStorage(
            applicationID: configuration.applicationID,
            environment: configuration.environment,
            rootKeychainAccessGroup: configuration.rootKeychainAccessGroup,
            legacySharedKeychainAccessGroups: configuration.legacySharedKeychainAccessGroups,
            clientRuntime: configuration.clientRuntime
        )
        let transport = LatchwayURLSessionTransport(session: LatchwayURLSessionFactory.make())
        let clock = LatchwaySystemClock()
        let attestation = configuration.attestationProvider ?? LatchwayUnavailableAttestationProvider()
        let proofFactory = LatchwayDPoPProofFactory(key: key, clock: clock)
        let componentRegistry = LatchwayKeychainComponentRegistry(
            applicationID: configuration.applicationID,
            environment: configuration.environment,
            rootKeychainAccessGroup: configuration.rootKeychainAccessGroup,
            legacySharedKeychainAccessGroups: configuration.legacySharedKeychainAccessGroups,
            clientRuntime: configuration.clientRuntime
        )

        self.configuration = configuration
        self.identityTokenProvider = identityTokenProvider
        self.attestationProvider = attestation
        self.installationKey = key
        self.sessionStorage = storage
        self.componentRegistry = componentRegistry
        self.componentStateRetirer = LatchwayKeychainComponentStateRetirer(configuration: configuration)
        self.transport = transport
        self.clock = clock
        self.proofFactory = proofFactory
        self.rootKeychainPreflight = LatchwayRootKeychainPreflight.verifier(
            rootKeychainAccessGroup: configuration.rootKeychainAccessGroup,
            legacySharedKeychainAccessGroups: configuration.legacySharedKeychainAccessGroups,
            applicationID: configuration.applicationID,
            environment: configuration.environment,
            clientRuntime: configuration.clientRuntime
        )
        self.controlPlane = LatchwayControlPlane(
            configuration: configuration,
            transport: transport,
            proofFactory: proofFactory,
            clock: clock
        )
    }

    public init(
        configuration: LatchwayConfiguration,
        identityTokenProvider: any LatchwayIdentityTokenProvider,
        attestationProvider: any LatchwayAttestationProvider,
        installationKey: any LatchwayInstallationKey,
        sessionStorage: any LatchwaySessionStorage,
        transport: any LatchwayHTTPTransport,
        clock: any LatchwayClock = LatchwaySystemClock()
    ) {
        let proofFactory = LatchwayDPoPProofFactory(key: installationKey, clock: clock)
        let componentRegistry = LatchwayKeychainComponentRegistry(
            applicationID: configuration.applicationID,
            environment: configuration.environment,
            rootKeychainAccessGroup: configuration.rootKeychainAccessGroup,
            legacySharedKeychainAccessGroups: configuration.legacySharedKeychainAccessGroups,
            clientRuntime: configuration.clientRuntime
        )
        self.configuration = configuration
        self.identityTokenProvider = identityTokenProvider
        self.attestationProvider = attestationProvider
        self.installationKey = installationKey
        self.sessionStorage = sessionStorage
        self.componentRegistry = componentRegistry
        self.componentStateRetirer = LatchwayKeychainComponentStateRetirer(configuration: configuration)
        self.transport = transport
        self.clock = clock
        self.proofFactory = proofFactory
        self.rootKeychainPreflight = LatchwayRootKeychainPreflight.verifier(
            rootKeychainAccessGroup: configuration.rootKeychainAccessGroup,
            legacySharedKeychainAccessGroups: configuration.legacySharedKeychainAccessGroups,
            applicationID: configuration.applicationID,
            environment: configuration.environment,
            clientRuntime: configuration.clientRuntime
        )
        self.controlPlane = LatchwayControlPlane(
            configuration: configuration,
            transport: transport,
            proofFactory: proofFactory,
            clock: clock
        )
    }

    init(
        configuration: LatchwayConfiguration,
        identityTokenProvider: any LatchwayIdentityTokenProvider,
        attestationProvider: any LatchwayAttestationProvider,
        installationKey: any LatchwayInstallationKey,
        sessionStorage: any LatchwaySessionStorage,
        transport: any LatchwayHTTPTransport,
        clock: any LatchwayClock,
        rootKeychainPreflight: @escaping @Sendable () throws -> Void,
        componentRegistry: (any LatchwayComponentRegistry)? = nil,
        componentStateRetirer: (any LatchwayComponentStateRetiring)? = nil
    ) {
        let proofFactory = LatchwayDPoPProofFactory(key: installationKey, clock: clock)
        self.configuration = configuration
        self.identityTokenProvider = identityTokenProvider
        self.attestationProvider = attestationProvider
        self.installationKey = installationKey
        self.sessionStorage = sessionStorage
        self.componentRegistry = componentRegistry ?? LatchwayKeychainComponentRegistry(
            applicationID: configuration.applicationID,
            environment: configuration.environment,
            rootKeychainAccessGroup: configuration.rootKeychainAccessGroup,
            legacySharedKeychainAccessGroups: configuration.legacySharedKeychainAccessGroups,
            clientRuntime: configuration.clientRuntime
        )
        self.componentStateRetirer = componentStateRetirer
            ?? LatchwayKeychainComponentStateRetirer(configuration: configuration)
        self.transport = transport
        self.clock = clock
        self.proofFactory = proofFactory
        self.rootKeychainPreflight = rootKeychainPreflight
        self.controlPlane = LatchwayControlPlane(
            configuration: configuration,
            transport: transport,
            proofFactory: proofFactory,
            clock: clock
        )
    }

    public func authorize(_ request: inout URLRequest, feature: String) async throws {
        try await authorize(
            &request,
            feature: feature,
            dpopNonce: nil,
            framework: nil,
            allowManagedPlaceholder: false
        )
    }

    /// Authorizes a request using a nonce supplied by a validated, same-origin
    /// `dpop_nonce_required` response.
    ///
    /// This overload exists for transports such as React Native fetch where
    /// the caller, rather than ``send(_:feature:)``, owns network dispatch.
    /// A nonce is opaque and non-secret, but must be one unambiguous printable
    /// ASCII field value before it is included in a signed proof.
    public func authorize(
        _ request: inout URLRequest,
        feature: String,
        nonce: String
    ) async throws {
        guard SafeRetryDirective.isValidNonce(nonce) else {
            throw LatchwayError.invalidRequest(
                "DPoP nonce must be one 16 to 512 byte printable ASCII value without whitespace or commas"
            )
        }
        try await authorize(
            &request,
            feature: feature,
            dpopNonce: nonce,
            framework: nil,
            allowManagedPlaceholder: false
        )
    }

    /// Creates a transport that binds every request to one feature and, when
    /// supplied, one framework integration identity.
    public nonisolated func transport(
        feature: String,
        framework: LatchwayFrameworkMetadata? = nil
    ) -> LatchwayFeatureTransport {
        makeFeatureTransport(
            feature: feature,
            framework: framework,
            session: nil
        )
    }

    /// Test-only injection keeps production streaming sessions private and
    /// independently cancellable while allowing deterministic URLProtocol
    /// coverage of response-head retry behavior.
    nonisolated func transport(
        feature: String,
        framework: LatchwayFrameworkMetadata? = nil,
        session: URLSession
    ) -> LatchwayFeatureTransport {
        makeFeatureTransport(
            feature: feature,
            framework: framework,
            session: session
        )
    }

    private nonisolated func makeFeatureTransport(
        feature: String,
        framework: LatchwayFrameworkMetadata?,
        session: URLSession?
    ) -> LatchwayFeatureTransport {
        LatchwayFeatureTransport(
            feature: feature,
            framework: framework,
            baseURL: configuration.baseURL,
            session: session,
            authorize: { [self] request in
                try await authorizedFrameworkRequest(
                    request,
                    feature: feature,
                    framework: framework
                )
            },
            send: { [self] request in
                try await send(
                    request,
                    feature: feature,
                    framework: framework,
                    allowManagedPlaceholder: true
                )
            },
            streamingRetry: { [self] request, authorized, directive in
                try await authorizedRetryRequest(
                    request,
                    firstAuthorizedRequest: authorized,
                    directive: directive,
                    feature: feature,
                    framework: framework,
                    allowManagedPlaceholder: true
                )
            }
        )
    }

    private func authorizedFrameworkRequest(
        _ request: URLRequest,
        feature: String,
        framework: LatchwayFrameworkMetadata?
    ) async throws -> URLRequest {
        var authorized = request
        try await authorize(
            &authorized,
            feature: feature,
            dpopNonce: nil,
            framework: framework,
            allowManagedPlaceholder: true
        )
        return authorized
    }

    /// Forces one single-flight session refresh without exposing session
    /// credentials. This is intended for caller-owned transports after a
    /// validated, same-origin `session_expired` rejection.
    public func refresh() async throws {
        try validateConfiguration()
        try ensureRootKeychainPreflight()
        _ = try await refreshSession(force: true)
    }

    private func authorize(
        _ request: inout URLRequest,
        feature: String,
        dpopNonce: String?,
        framework: LatchwayFrameworkMetadata?,
        allowManagedPlaceholder: Bool
    ) async throws {
        guard !Task.isCancelled else { throw LatchwayError.cancelled }
        try validateConfiguration()
        try ensureRootKeychainPreflight()
        try validateFeature(feature)
        try LatchwayComponentRequestSecurity.prepare(
            &request,
            configuration: configuration,
            feature: feature,
            framework: framework,
            allowManagedPlaceholder: allowManagedPlaceholder
        )
        guard let url = request.url else { throw LatchwayError.invalidServerResponse }
        let method = request.httpMethod?.uppercased() ?? "GET"

        let active = try await activeSession()
        guard !Task.isCancelled else { throw LatchwayError.cancelled }
        let proof = try await proofFactory.proof(
            method: method,
            url: url,
            accessToken: active.accessToken,
            nonce: dpopNonce
        )
        guard !Task.isCancelled else { throw LatchwayError.cancelled }
        request.setValue("DPoP \(active.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(proof, forHTTPHeaderField: "DPoP")
        request.setValue(feature, forHTTPHeaderField: "X-Latchway-Feature")
        LatchwayComponentRequestSecurity.addMetadata(
            to: &request,
            configuration: configuration,
            framework: framework
        )
    }

    /// Authorizes and sends a buffered request through the configured transport.
    ///
    /// This method retries at most once, and only for `session_expired` or
    /// `dpop_nonce_required`, which the wire contract defines as rejection
    /// before upstream dispatch. Requests backed by an `httpBodyStream` are
    /// never replayed. Streaming callers should use
    /// ``LatchwayFeatureTransport/bytes(for:)`` for the same bounded policy
    /// without buffering successful response bodies.
    public func send(_ request: URLRequest, feature: String) async throws -> LatchwayHTTPResponse {
        try await send(
            request,
            feature: feature,
            framework: nil,
            allowManagedPlaceholder: false
        )
    }

    private func send(
        _ request: URLRequest,
        feature: String,
        framework: LatchwayFrameworkMetadata?,
        allowManagedPlaceholder: Bool
    ) async throws -> LatchwayHTTPResponse {
        var firstRequest = request
        try await authorize(
            &firstRequest,
            feature: feature,
            dpopNonce: nil,
            framework: framework,
            allowManagedPlaceholder: allowManagedPlaceholder
        )
        let firstResponse = try await sendThroughTransport(firstRequest)
        if (300 ... 399).contains(firstResponse.statusCode) {
            let error = LatchwayError.invalidServerResponse
            await record(error)
            throw error
        }
        guard (400 ... 599).contains(firstResponse.statusCode) else { return firstResponse }
        let retryRequest = try await authorizedRetryRequest(
            request,
            firstAuthorizedRequest: firstRequest,
            response: firstResponse,
            feature: feature,
            framework: framework,
            allowManagedPlaceholder: allowManagedPlaceholder
        )

        let secondResponse = try await sendThroughTransport(retryRequest)
        if (300 ... 399).contains(secondResponse.statusCode) {
            let error = LatchwayError.invalidServerResponse
            await record(error)
            throw error
        }
        if (400 ... 599).contains(secondResponse.statusCode) {
            guard let problem = Self.problem(from: secondResponse) else {
                let error = LatchwayError.invalidServerResponse
                await record(error)
                throw error
            }
            let error = LatchwayError.server(problem)
            await record(error)
            throw error
        }
        return secondResponse
    }

    private func authorizedRetryRequest(
        _ request: URLRequest,
        firstAuthorizedRequest: URLRequest,
        response: LatchwayHTTPResponse,
        feature: String,
        framework: LatchwayFrameworkMetadata?,
        allowManagedPlaceholder: Bool
    ) async throws -> URLRequest {
        guard let firstProblem = Self.problem(from: response) else {
            let error = LatchwayError.invalidServerResponse
            await record(error)
            throw error
        }
        guard request.httpBodyStream == nil else {
            let error = LatchwayError.server(firstProblem)
            await record(error)
            throw error
        }
        guard let directive = SafeRetryDirective.parse(
            response: response,
            expectedRequestID: firstAuthorizedRequest.value(
                forHTTPHeaderField: "X-Latchway-Request-ID"
            )
        ) else {
            let error = LatchwayError.server(firstProblem)
            await record(error)
            throw error
        }

        return try await authorizedRetryRequest(
            request,
            firstAuthorizedRequest: firstAuthorizedRequest,
            directive: directive,
            feature: feature,
            framework: framework,
            allowManagedPlaceholder: allowManagedPlaceholder
        )
    }

    private func authorizedRetryRequest(
        _ request: URLRequest,
        firstAuthorizedRequest: URLRequest,
        directive: SafeRetryDirective,
        feature: String,
        framework: LatchwayFrameworkMetadata?,
        allowManagedPlaceholder: Bool
    ) async throws -> URLRequest {
        var retry = request
        retry.setValue(
            firstAuthorizedRequest.value(forHTTPHeaderField: "X-Latchway-Request-ID"),
            forHTTPHeaderField: "X-Latchway-Request-ID"
        )
        switch directive {
        case .sessionExpired:
            let refreshed = try await refreshSession(force: true)
            try await applyAuthorization(
                &retry,
                feature: feature,
                active: refreshed,
                nonce: nil,
                framework: framework,
                allowManagedPlaceholder: allowManagedPlaceholder
            )
        case let .dpopNonceRequired(nonce):
            let active = try await activeSession()
            try await applyAuthorization(
                &retry,
                feature: feature,
                active: active,
                nonce: nonce,
                framework: framework,
                allowManagedPlaceholder: allowManagedPlaceholder
            )
        }
        return retry
    }

    /// Creates the SDK's hardened URL session for lower-level caller-owned
    /// dispatch. This session does not authorize or retry requests; prefer
    /// ``LatchwayFeatureTransport/bytes(for:)`` for streaming data-plane work.
    public func makeURLSession() -> URLSession {
        LatchwayURLSessionFactory.make()
    }

    public func quota(feature: String) async throws -> LatchwayQuotaSnapshot {
        try validateFeature(feature)
        let active = try await activeSession()
        do {
            let snapshot: LatchwayQuotaSnapshot
            do {
                snapshot = try await controlPlane.quota(
                    feature: feature,
                    accessToken: active.accessToken
                )
            } catch let error as LatchwayError where error.isSafeRefreshRejection {
                let refreshed = try await refreshSession(force: true)
                snapshot = try await controlPlane.quota(
                    feature: feature,
                    accessToken: refreshed.accessToken
                )
            }
            return try validatedQuota(snapshot, feature: feature)
        } catch let error as LatchwayError {
            await record(error)
            throw error
        } catch {
            let error = LatchwayError.transportFailure
            await record(error)
            throw error
        }
    }

    public func revokeCurrentInstallation() async throws {
        let active = try await activeSession()
        do {
            do {
                try await controlPlane.revoke(accessToken: active.accessToken)
            } catch let error as LatchwayError where error.isSafeRefreshRejection {
                let refreshed = try await refreshSession(force: true)
                try await controlPlane.revoke(accessToken: refreshed.accessToken)
            }
        } catch let error as LatchwayError {
            await record(error)
            throw error
        } catch {
            let error = LatchwayError.transportFailure
            await record(error)
            throw error
        }

        try await retireAfterRevocation()
    }

    /// Revokes the complete installation family and retires the root plus every
    /// durably registered delegated-component credential and key locally.
    ///
    /// Successful and reused component preparations are recorded as non-secret
    /// descriptors in the root application's private Keychain group. Failed
    /// component erasures remain registered so a later launch can retry them.
    public func revokeCurrentInstallationFamily() async throws {
        try await revokeCurrentInstallationFamily(retiring: [])
    }

    /// Revokes the complete installation family, including every registered or
    /// explicitly supplied delegated component, then erases local key material.
    ///
    /// The descriptor overload remains available for compatibility and for
    /// retiring legacy component state that predates the durable registry.
    public func revokeCurrentInstallationFamily(
        retiring components: [LatchwayComponentConfiguration]
    ) async throws {
        let definitions = components.map(\.definitionID)
        guard Set(definitions).count == definitions.count else {
            throw LatchwayComponentError.invalidConfiguration(
                "component definition IDs must be unique in one retirement call"
            )
        }
        try components.forEach(validateComponentConfiguration)
        var firstError: (any Error)?
        do {
            let active = try await activeSession()
            do {
                try await controlPlane.revokeFamily(accessToken: active.accessToken)
            } catch let error as LatchwayError where error.isSafeRefreshRejection {
                let refreshed = try await refreshSession(force: true)
                try await controlPlane.revokeFamily(accessToken: refreshed.accessToken)
            }
        } catch let error as LatchwayError {
            await record(error)
            firstError = error
        } catch {
            let transportError = LatchwayError.transportFailure
            await record(transportError)
            firstError = transportError
        }

        do {
            try await LatchwayComponentFamilyRetirement.retireAll(
                registry: componentRegistry,
                including: components,
                retire: { [self] component in try await retireComponentState(component) }
            )
        } catch {
            firstError = firstError ?? error
        }
        do { try await retireAfterRevocation() }
        catch { firstError = firstError ?? error }

        if let firstError { throw firstError }
    }

    /// Provisions every missing or expired delegated component. Existing,
    /// still-valid credentials bound to the current component key are reused;
    /// use ``replaceComponent(_:)`` for an explicit key replacement.
    @discardableResult
    public func prepareComponents(
        _ components: [LatchwayComponentConfiguration]
    ) async throws -> [LatchwayComponentDiagnostics] {
        let definitions = components.map(\.definitionID)
        guard Set(definitions).count == definitions.count else {
            throw LatchwayComponentError.invalidConfiguration(
                "component definition IDs must be unique in one preparation call"
            )
        }
        var diagnostics: [LatchwayComponentDiagnostics] = []
        diagnostics.reserveCapacity(components.count)
        for component in components {
            diagnostics.append(try await prepareComponent(component, replacing: false))
        }
        return diagnostics
    }

    /// Replaces one delegated component key and invalidates its previous server
    /// session family through the provisioning endpoint.
    @discardableResult
    public func replaceComponent(
        _ component: LatchwayComponentConfiguration
    ) async throws -> LatchwayComponentDiagnostics {
        try await prepareComponent(component, replacing: true)
    }

    /// Revokes one delegated component without revoking its siblings.
    public func revokeComponent(_ component: LatchwayComponentConfiguration) async throws {
        try validateComponentConfiguration(component)
        let storage = componentStorage(for: component)
        guard let stored = try await storage.load() else {
            throw LatchwayComponentError.componentNotProvisioned
        }
        let active = try await activeSession()
        do {
            try await controlPlane.revokeComponent(
                componentID: stored.component.id,
                accessToken: active.accessToken
            )
        } catch let error as LatchwayError {
            throw Self.componentError(from: error)
        }
        try await retireComponentState(component)
        try await componentRegistry.unregister(component)
    }

    public func componentDiagnostics(
        _ component: LatchwayComponentConfiguration
    ) async -> LatchwayComponentDiagnostics {
        let key = componentKey(for: component)
        let keyStorage = await key.storage()
        let thumbprint = try? await LatchwayDPoPProofFactory(
            key: key,
            clock: clock
        ).thumbprint()
        let credential = try? await componentStorage(for: component).load()
        return Self.componentDiagnostics(
            component: component,
            keyStorage: keyStorage,
            keyThumbprint: thumbprint,
            credential: credential,
            sessionAvailable: false,
            now: await clock.now()
        )
    }

    public func diagnostics() async -> LatchwayDiagnostics {
        do {
            try validateConfiguration()
            try ensureRootKeychainPreflight()
        } catch let error as LatchwayError {
            state = .failed
            lastErrorCode = error.stableLocalCode
            return LatchwayDiagnostics(
                sdkVersion: configuration.clientSDKVersion,
                keyStorage: .unavailable,
                keyThumbprint: nil,
                attestation: LatchwayAttestationStatus(
                    support: .unknown,
                    lastOperation: "root_keychain_preflight_failed"
                ),
                sessionState: state,
                sessionExpiresAt: nil,
                installationID: nil,
                installationFamilyID: nil,
                componentID: nil,
                componentDefinitionID: nil,
                componentKind: nil,
                serverVersion: serverVersion,
                trustProvider: nil,
                trustLevel: nil,
                lastRequestID: lastRequestID,
                lastErrorCode: lastErrorCode
            )
        } catch {
            state = .failed
            lastErrorCode = LatchwayError.keyStorageFailure.stableLocalCode
            return LatchwayDiagnostics(
                sdkVersion: configuration.clientSDKVersion,
                keyStorage: .unavailable,
                keyThumbprint: nil,
                attestation: LatchwayAttestationStatus(
                    support: .unknown,
                    lastOperation: "root_keychain_preflight_failed"
                ),
                sessionState: state,
                sessionExpiresAt: nil,
                installationID: nil,
                installationFamilyID: nil,
                componentID: nil,
                componentDefinitionID: nil,
                componentKind: nil,
                serverVersion: serverVersion,
                trustProvider: nil,
                trustLevel: nil,
                lastRequestID: lastRequestID,
                lastErrorCode: lastErrorCode
            )
        }
        let keyStorage = await installationKey.storage()
        let thumbprint = try? await proofFactory.thumbprint()
        let attestation = await attestationProvider.status()
        var installationID = session?.installation.id
        var installationFamilyID = session?.installationFamily?.id
        var component = session?.component
        var expiration = session?.expiresAt
        var trustProvider: String?
        var trustLevel: String?

        if let active = session, active.isUsable(at: await clock.now()) {
            // The accepted grant is the authority for this session's trust.
            // A later diagnostics response may update server metadata but must
            // never upgrade the trust bound to the active access token.
            trustProvider = active.trust.provider
            trustLevel = active.trust.level
            if let remote = try? await controlPlane.diagnostics(accessToken: active.accessToken),
               Self.validDiagnostics(remote, active: active, thumbprint: thumbprint) {
                serverVersion = remote.serverVersion
                lastRequestID = remote.requestID
                installationID = remote.installation.id
                installationFamilyID = remote.installationFamily?.id ?? installationFamilyID
                component = remote.component ?? component
                expiration = remote.session.expiresAt
            }
        }
        return LatchwayDiagnostics(
            sdkVersion: configuration.clientSDKVersion,
            keyStorage: keyStorage,
            keyThumbprint: thumbprint,
            attestation: attestation,
            sessionState: state,
            sessionExpiresAt: expiration,
            installationID: installationID,
            installationFamilyID: installationFamilyID,
            componentID: component?.id,
            componentDefinitionID: component?.definitionID,
            componentKind: component?.kind,
            serverVersion: serverVersion,
            trustProvider: trustProvider,
            trustLevel: trustLevel,
            lastRequestID: lastRequestID,
            lastErrorCode: lastErrorCode
        )
    }

    private func activeSession() async throws -> RuntimeSession {
        try validateConfiguration()
        try ensureRootKeychainPreflight()
        if state == .revoked { throw terminalError ?? LatchwayError.sessionUnavailable }
        let now = await clock.now()
        if let session, session.isUsable(at: now) {
            state = .active
            return session
        }
        if refreshTask != nil { return try await refreshSession(force: true) }
        if establishmentTask != nil { return try await establishSession() }

        if session != nil { return try await refreshSession(force: true) }
        do {
            let stored = try await sessionStorage.load()
            let resumedAt = await clock.now()
            if let session, session.isUsable(at: resumedAt) {
                state = .active
                return session
            }
            if refreshTask != nil { return try await refreshSession(force: true) }
            if establishmentTask != nil { return try await establishSession() }
            if let stored, stored.refreshExpiresAt > resumedAt {
                return try await refreshStoredSession(stored)
            }
        } catch let error as LatchwayError {
            await record(error)
            throw error
        }
        return try await establishSession()
    }

    private func establishSession() async throws -> RuntimeSession {
        if let establishmentTask { return try await resolve(establishmentTask, kind: .establishing) }
        state = .establishing
        let task = Task { [identityTokenProvider, attestationProvider, controlPlane, proofFactory, sessionStorage, configuration, clock] in
            try await Self.performEstablishment(
                identityTokenProvider: identityTokenProvider,
                attestationProvider: attestationProvider,
                controlPlane: controlPlane,
                proofFactory: proofFactory,
                sessionStorage: sessionStorage,
                configuration: configuration,
                clock: clock
            )
        }
        establishmentTask = task
        defer { establishmentTask = nil }
        return try await resolve(task, kind: .establishing)
    }

    private func refreshSession(force: Bool) async throws -> RuntimeSession {
        if state == .revoked { throw terminalError ?? LatchwayError.sessionUnavailable }
        if !force, let session, session.isUsable(at: await clock.now()) { return session }
        if let refreshTask { return try await resolve(refreshTask, kind: .refreshing) }
        let stored: LatchwayStoredSession
        if let session {
            stored = LatchwayStoredSession(
                refreshToken: session.refreshToken,
                refreshExpiresAt: session.refreshExpiresAt,
                installation: session.installation,
                installationFamily: session.installationFamily,
                component: session.component
            )
        } else if let loaded = try await sessionStorage.load() {
            stored = loaded
        } else {
            return try await establishSession()
        }
        return try await refreshStoredSession(stored)
    }

    private func refreshStoredSession(_ stored: LatchwayStoredSession) async throws -> RuntimeSession {
        if let refreshTask { return try await resolve(refreshTask, kind: .refreshing) }
        state = .refreshing
        let task = Task { [self, controlPlane, identityTokenProvider, attestationProvider, proofFactory, sessionStorage, configuration, clock] in
            try Task.checkCancellation()
            let now = await clock.now()
            let remainingLifetime = stored.refreshExpiresAt.timeIntervalSince(now)
            let expectedThumbprint = try await proofFactory.thumbprint()
            guard (32 ... 2_048).contains(stored.refreshToken.utf8.count),
                  remainingLifetime.isFinite,
                  remainingLifetime > 0,
                  remainingLifetime <= 31_536_300,
                  stored.installation.id.range(
                      of: "^ins_[A-Za-z0-9_-]{16,128}$",
                      options: .regularExpression
                  ) != nil,
                  stored.installation.platform == configuration.clientRuntime.platformIdentifier,
                  stored.installation.status == "active",
                  stored.installation.dpopJKT == expectedThumbprint,
                  Self.validRootBinding(
                      family: stored.installationFamily,
                      component: stored.component,
                      expectedThumbprint: expectedThumbprint,
                      platform: configuration.clientRuntime.platformIdentifier
                  )
            else {
                try await self.retireSessionForAttestedReestablishment()
                return try await Self.performEstablishment(
                    identityTokenProvider: identityTokenProvider,
                    attestationProvider: attestationProvider,
                    controlPlane: controlPlane,
                    proofFactory: proofFactory,
                    sessionStorage: sessionStorage,
                    configuration: configuration,
                    clock: clock
                )
            }
            let grant: SessionGrantWire
            do {
                grant = try await controlPlane.refresh(refreshToken: stored.refreshToken)
            } catch let error as LatchwayError where error.requiresAttestedReestablishment {
                // The v1 refresh contract accepts only refresh_token. Retire
                // the stored session and run the ordinary challenge + attested
                // exchange inside this single-flight task so every waiter
                // observes the same replacement session.
                try await self.retireSessionForAttestedReestablishment()
                return try await Self.performEstablishment(
                    identityTokenProvider: identityTokenProvider,
                    attestationProvider: attestationProvider,
                    controlPlane: controlPlane,
                    proofFactory: proofFactory,
                    sessionStorage: sessionStorage,
                    configuration: configuration,
                    clock: clock
                )
            }
            return try await Self.accept(
                grant: grant,
                issuedAt: await clock.now(),
                expectedThumbprint: expectedThumbprint,
                storage: sessionStorage,
                configuration: configuration
            )
        }
        refreshTask = task
        defer { refreshTask = nil }
        do { return try await resolve(task, kind: .refreshing) }
        catch let error as LatchwayError {
            if error == .keyStorageFailure {
                // Legacy root sessions remain on the wire-1 terminal reuse
                // profile. The server may have consumed this refresh token, so
                // discard every local copy rather than replaying it.
                await clearSession()
            } else if error.requiresFreshSession {
                if error.isRevocation {
                    state = .revoked
                    terminalError = error
                } else {
                    await clearSession()
                }
            }
            throw error
        }
    }

    private func retireSessionForAttestedReestablishment() async throws {
        // Retire the actor-visible session before any fallible identity or
        // attestation work. If replacement fails, no caller may resume using
        // the grant for which the server required step-up.
        session = nil
        do {
            try await sessionStorage.clear()
        } catch {
            throw LatchwayError.keyStorageFailure
        }
    }

    private static func performEstablishment(
        identityTokenProvider: any LatchwayIdentityTokenProvider,
        attestationProvider: any LatchwayAttestationProvider,
        controlPlane: LatchwayControlPlane,
        proofFactory: LatchwayDPoPProofFactory,
        sessionStorage: any LatchwaySessionStorage,
        configuration: LatchwayConfiguration,
        clock: any LatchwayClock
    ) async throws -> RuntimeSession {
        try Task.checkCancellation()
        let identityToken = try await identityTokenProvider.identityToken()
        guard (16 ... 65_536).contains(identityToken.utf8.count) else {
            throw LatchwayError.invalidRequest("The identity token has an invalid length")
        }
        let challenge = try await controlPlane.createChallenge(identityToken: identityToken)
        let now = await clock.now()
        let issuedAt = Date(timeIntervalSince1970: TimeInterval(challenge.issuedAt))
        let challengeTTL = challenge.expiresAt.timeIntervalSince(issuedAt)
        guard challenge.bindingVersion == 1,
              challenge.challengeID.range(
                  of: "^chl_[A-Za-z0-9_-]{16,128}$",
                  options: .regularExpression
              ) != nil,
              challenge.challengeNonce.range(
                  of: "^[A-Za-z0-9_-]+$",
                  options: .regularExpression
              ) != nil,
              challenge.issuedAt >= 0,
              issuedAt <= now.addingTimeInterval(300),
              challengeTTL > 0,
              challenge.expiresAt > now,
              ["required", "preferred"].contains(challenge.attestation.mode),
              ["app_attest", "play_integrity", "firebase_app_check", "turnstile", "debug"]
                  .contains(challenge.attestation.provider),
              challenge.attestation.clientDataHash.utf8.count == 43,
              let clientDataHash = try? Base64URL.decode(challenge.attestation.clientDataHash),
              clientDataHash.count == 32
        else { throw LatchwayError.invalidAttestationBinding }

        let attestationChallenge = LatchwayAttestationChallenge(
            id: challenge.challengeID,
            provider: challenge.attestation.provider,
            clientDataHash: clientDataHash,
            expiresAt: challenge.expiresAt,
            options: challenge.attestation.providerOptions ?? [:]
        )
        let evidence = try await attestationProvider.evidence(for: attestationChallenge)
        guard evidence.provider == challenge.attestation.provider else {
            throw LatchwayError.attestationUnavailable
        }
        let grant = try await controlPlane.exchange(challengeID: challenge.challengeID, evidence: evidence)
        let expectedThumbprint = try await proofFactory.thumbprint()
        let accepted = try await Self.accept(
            grant: grant,
            issuedAt: await clock.now(),
            expectedThumbprint: expectedThumbprint,
            storage: sessionStorage,
            configuration: configuration
        )
        await attestationProvider.didAccept(evidence)
        return accepted
    }

    private func resolve(_ task: Task<RuntimeSession, Error>, kind: LatchwayDiagnostics.SessionState) async throws -> RuntimeSession {
        state = kind
        do {
            let result = try await task.value
            session = result
            state = .active
            lastErrorCode = nil
            return result
        } catch is CancellationError {
            state = session == nil ? .absent : .expired
            throw LatchwayError.cancelled
        } catch let error as LatchwayError {
            await record(error)
            throw error
        } catch {
            state = .failed
            lastErrorCode = "transport_failure"
            throw LatchwayError.sessionUnavailable
        }
    }

    private static func accept(
        grant: SessionGrantWire,
        issuedAt: Date,
        expectedThumbprint: String,
        storage: any LatchwaySessionStorage,
        configuration: LatchwayConfiguration
    ) async throws -> RuntimeSession {
        guard grant.tokenType == "DPoP",
              (60 ... 3_600).contains(grant.expiresIn),
              (300 ... 31_536_000).contains(grant.refreshExpiresIn),
              (64 ... 16_384).contains(grant.accessToken.utf8.count),
              (32 ... 2_048).contains(grant.refreshToken.utf8.count),
              grant.installation.platform == configuration.clientRuntime.platformIdentifier,
              grant.installation.status == "active",
              grant.installation.dpopJKT == expectedThumbprint,
              grant.installation.id.range(
                  of: "^ins_[A-Za-z0-9_-]{16,128}$",
                  options: .regularExpression
              ) != nil,
              Self.validRootBinding(
                  family: grant.installationFamily,
                  component: grant.component,
                  expectedThumbprint: expectedThumbprint,
                  platform: configuration.clientRuntime.platformIdentifier
              ),
              Self.validRootTrustBinding(
                  grant.trust,
                  family: grant.installationFamily,
                  component: grant.component
              ),
              [
                  "none", "identity_only", "web_risk_verified", "app_verified",
                  "device_verified", "strong_device_verified", "debug",
              ].contains(grant.trust.level),
              grant.trust.verifiedAt <= issuedAt.addingTimeInterval(300),
              grant.trust.expiresAt > issuedAt,
              !configuration.applicationID.isEmpty
        else { throw LatchwayError.invalidServerResponse }

        let runtime = RuntimeSession(
            accessToken: grant.accessToken,
            expiresAt: issuedAt.addingTimeInterval(TimeInterval(grant.expiresIn)),
            refreshToken: grant.refreshToken,
            refreshExpiresAt: issuedAt.addingTimeInterval(TimeInterval(grant.refreshExpiresIn)),
            installation: grant.installation,
            installationFamily: grant.installationFamily,
            component: grant.component,
            trust: grant.trust
        )
        do {
            try await storage.save(LatchwayStoredSession(
                refreshToken: runtime.refreshToken,
                refreshExpiresAt: runtime.refreshExpiresAt,
                installation: runtime.installation,
                installationFamily: runtime.installationFamily,
                component: runtime.component
            ))
        } catch {
            // A failed write after legacy root refresh must not leave the
            // previously rotated token available for accidental reuse.
            try? await storage.clear()
            throw LatchwayError.keyStorageFailure
        }
        return runtime
    }

    private func clearSession() async {
        session = nil
        establishmentTask?.cancel()
        establishmentTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        try? await sessionStorage.clear()
        state = .absent
    }

    private func retireAfterRevocation() async throws {
        session = nil
        establishmentTask?.cancel()
        establishmentTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        var cleanupError: LatchwayError?
        do { try await sessionStorage.clear() }
        catch { cleanupError = .keyStorageFailure }
        do { try await attestationProvider.reset() }
        catch let error as LatchwayError { cleanupError = cleanupError ?? error }
        catch { cleanupError = cleanupError ?? .attestationUnavailable }
        do { try await installationKey.reset() }
        catch { cleanupError = cleanupError ?? .keyStorageFailure }
        state = .revoked
        if let cleanupError {
            lastErrorCode = cleanupError.stableLocalCode
            throw cleanupError
        }
    }

    private func prepareComponent(
        _ component: LatchwayComponentConfiguration,
        replacing: Bool
    ) async throws -> LatchwayComponentDiagnostics {
        try validateComponentConfiguration(component)
        let active = try await activeSession()
        // Persist the safe Keychain coordinate before any component-local
        // access or mutation. If provisioning later fails, retaining a
        // harmless stale descriptor is preferable to leaving secret state
        // untracked.
        try await componentRegistry.register(component)
        let prior = try await componentStorage(for: component).load()
        let changedFamily = prior.map { stored in
            active.installationFamily?.id != stored.family.id
        } ?? false
        if replacing || changedFamily {
            try await retireComponentState(component)
        }
        let key = componentKey(for: component)
        let storage = componentStorage(for: component)

        let proofFactory = LatchwayDPoPProofFactory(key: key, clock: clock)
        let thumbprint: String
        do {
            thumbprint = try await proofFactory.thumbprint()
        } catch let error as LatchwayComponentError {
            throw error
        } catch {
            throw LatchwayComponentError.componentKeyUnavailable
        }
        let now = await clock.now()
        if !replacing,
           let existing = try await storage.load(),
           existing.isValid(
               for: component,
               keyThumbprint: thumbprint,
               now: now,
               rotationLeeway: 60
           ) {
            return Self.componentDiagnostics(
                component: component,
                keyStorage: await key.storage(),
                keyThumbprint: thumbprint,
                credential: existing,
                sessionAvailable: existing.kind == .sessionRefreshToken,
                now: now
            )
        }

        let grant: ComponentProvisioningWire
        do {
            grant = try await controlPlane.provisionComponent(
                definitionID: component.definitionID,
                publicJWK: try await key.publicJWK(),
                requestedFeatures: component.requestedFeatures,
                accessToken: active.accessToken
            )
        } catch let error as LatchwayError {
            throw Self.componentError(from: error)
        }
        let credential = try Self.validatedComponentProvisioning(
            grant,
            component: component,
            keyThumbprint: thumbprint,
            expectedFamilyID: active.installationFamily?.id,
            parentTrust: active.trust,
            now: await clock.now()
        )
        try await storage.save(credential)
        return Self.componentDiagnostics(
            component: component,
            keyStorage: await key.storage(),
            keyThumbprint: thumbprint,
            credential: credential,
            sessionAvailable: false,
            now: await clock.now()
        )
    }

    private func componentKey(
        for component: LatchwayComponentConfiguration
    ) -> LatchwayComponentKeyManager {
        LatchwayComponentKeyManager(
            applicationID: configuration.applicationID,
            environment: configuration.environment,
            definitionID: component.definitionID,
            keychainAccessGroup: component.keychainAccessGroup,
            softwareFallbackPolicy: configuration.softwareKeyFallbackPolicy
        )
    }

    private func componentStorage(
        for component: LatchwayComponentConfiguration
    ) -> LatchwayKeychainComponentStorage {
        LatchwayKeychainComponentStorage(
            applicationID: configuration.applicationID,
            environment: configuration.environment,
            definitionID: component.definitionID,
            accessGroup: component.keychainAccessGroup
        )
    }

    private func retireComponentState(
        _ component: LatchwayComponentConfiguration
    ) async throws {
        try await componentStateRetirer.retire(component)
    }

    private func validateComponentConfiguration(
        _ component: LatchwayComponentConfiguration
    ) throws {
        try component.validateForContainingApplication()
    }

    private static func validatedComponentProvisioning(
        _ grant: ComponentProvisioningWire,
        component: LatchwayComponentConfiguration,
        keyThumbprint: String,
        expectedFamilyID: String?,
        parentTrust: LatchwayTrustSummary,
        now: Date
    ) throws -> LatchwayStoredComponentCredential {
        guard grant.componentID.range(
            of: "^cmp_[A-Za-z0-9_-]{16,128}$",
            options: .regularExpression
        ) != nil,
        grant.installationFamilyID.range(
            of: "^fam_[A-Za-z0-9_-]{16,128}$",
            options: .regularExpression
        ) != nil,
        expectedFamilyID == nil || grant.installationFamilyID == expectedFamilyID,
        grant.componentDefinitionID == nil || grant.componentDefinitionID == component.definitionID,
        grant.componentKind == nil || grant.componentKind == component.kind,
        grant.trust.expiresAt > now,
        grant.trust.expiresAt <= parentTrust.expiresAt,
        grant.trust.source != .delegatedFromAttestedRoot || [
            "app_verified", "device_verified", "strong_device_verified",
        ].contains(parentTrust.level),
        grant.refreshGrantExpiresAt > now,
        grant.refreshGrantExpiresAt.timeIntervalSince(now) <= 2_592_300,
        (32 ... 2_048).contains(grant.refreshGrant.utf8.count),
        !grant.grantedFeatures.isEmpty,
        grant.grantedFeatures.count <= 256,
        Set(grant.grantedFeatures).count == grant.grantedFeatures.count,
        Set(grant.grantedFeatures).isSubset(of: Set(component.requestedFeatures)),
        grant.grantedFeatures.allSatisfy({ feature in
            feature.range(of: "^[a-z][a-z0-9_-]{0,62}$", options: .regularExpression) != nil
        }) else {
            throw LatchwayError.invalidServerResponse
        }

        return LatchwayStoredComponentCredential(
            family: .init(id: grant.installationFamilyID, status: "active"),
            component: .init(
                id: grant.componentID,
                definitionID: component.definitionID,
                kind: component.kind,
                platform: "ios",
                isRoot: false,
                dpopJKT: keyThumbprint,
                status: "active",
                grantedFeatures: grant.grantedFeatures
            ),
            requestedFeatures: component.requestedFeatures.sorted(),
            trustSource: grant.trust.source,
            trustExpiresAt: grant.trust.expiresAt,
            keyThumbprint: keyThumbprint,
            rotationToken: grant.refreshGrant,
            rotationExpiresAt: grant.refreshGrantExpiresAt,
            kind: .provisioningGrant
        )
    }

    private static func componentDiagnostics(
        component: LatchwayComponentConfiguration,
        keyStorage: LatchwayKeyStorage,
        keyThumbprint: String?,
        credential: LatchwayStoredComponentCredential?,
        sessionAvailable: Bool,
        now: Date
    ) -> LatchwayComponentDiagnostics {
        let usable = credential.flatMap { credential in
            keyThumbprint.map { thumbprint in
                credential.isValid(
                    for: component,
                    keyThumbprint: thumbprint,
                    now: now
                )
            }
        } ?? false
        return LatchwayComponentDiagnostics(
            familyID: credential?.family.id,
            componentID: credential?.component.id,
            definitionID: component.definitionID,
            keychainAccessGroup: component.keychainAccessGroup,
            keyAvailable: keyStorage != .unavailable,
            keyStorage: keyStorage,
            grantAvailable: usable,
            sessionAvailable: usable && sessionAvailable,
            trustSource: credential?.trustSource,
            trustExpiresAt: credential?.trustExpiresAt,
            containingAppActionRequired: !usable
        )
    }

    private static func componentError(from error: LatchwayError) -> LatchwayComponentError {
        guard case let .server(problem) = error else { return .latchway(error) }
        return switch problem.code {
        case .containingAppSetupRequired: .containingAppSetupRequired
        case .componentDefinitionNotFound, .componentNotConfigured, .componentNotProvisioned:
            .componentNotProvisioned
        case .componentRevoked, .componentKeyReplaced, .sessionRevoked, .refreshTokenReused:
            .componentRevoked
        case .componentKeyInvalid: .componentKeyUnavailable
        case .installationRevoked, .installationFamilyRevoked, .installationFamilyNotFound:
            .installationFamilyRevoked
        case .componentDelegationExpired, .componentParentTrustExpired: .parentTrustExpired
        case .componentFeatureNotGranted: .featureNotDelegated
        case .componentDirectAttestationRequired, .attestationStepUpRequired:
            .directAttestationRequired
        case .identityReauthenticationRequired, .identityTokenExpired, .identityTokenInvalid:
            .identityChanged
        default: .latchway(error)
        }
    }

    private func validateFeature(_ feature: String) throws {
        guard feature.range(of: "^[a-z][a-z0-9_-]{0,62}$", options: .regularExpression) != nil else {
            throw LatchwayError.invalidRequest("feature must be a valid Latchway identifier")
        }
    }

    private func validatedQuota(
        _ snapshot: LatchwayQuotaSnapshot,
        feature: String
    ) throws -> LatchwayQuotaSnapshot {
        guard snapshot.feature == feature,
              snapshot.limits.count <= 128,
              snapshot.limits.allSatisfy({ limit in
                  [limit.maximum, limit.used, limit.reserved, limit.remaining]
                      .allSatisfy { value in value.map { $0 >= 0 } ?? true }
              })
        else { throw LatchwayError.invalidServerResponse }
        return snapshot
    }

    private func sendThroughTransport(_ request: URLRequest) async throws -> LatchwayHTTPResponse {
        do { return try await transport.send(request) }
        catch is CancellationError {
            let error = LatchwayError.cancelled
            await record(error)
            throw error
        } catch let error as LatchwayError {
            await record(error)
            throw error
        } catch {
            let error = LatchwayError.transportFailure
            await record(error)
            throw error
        }
    }

    private func applyAuthorization(
        _ request: inout URLRequest,
        feature: String,
        active: RuntimeSession,
        nonce: String?,
        framework: LatchwayFrameworkMetadata?,
        allowManagedPlaceholder: Bool
    ) async throws {
        try validateFeature(feature)
        try LatchwayComponentRequestSecurity.prepare(
            &request,
            configuration: configuration,
            feature: feature,
            framework: framework,
            allowManagedPlaceholder: allowManagedPlaceholder
        )
        guard let url = request.url else { throw LatchwayError.invalidServerResponse }
        guard !Task.isCancelled else { throw LatchwayError.cancelled }
        let method = request.httpMethod?.uppercased() ?? "GET"
        let proof = try await proofFactory.proof(method: method, url: url, accessToken: active.accessToken, nonce: nonce)
        guard !Task.isCancelled else { throw LatchwayError.cancelled }
        request.setValue("DPoP \(active.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(proof, forHTTPHeaderField: "DPoP")
        request.setValue(feature, forHTTPHeaderField: "X-Latchway-Feature")
        LatchwayComponentRequestSecurity.addMetadata(
            to: &request,
            configuration: configuration,
            framework: framework
        )
    }

    static func problem(from response: LatchwayHTTPResponse) -> LatchwayProblem? {
        guard (400 ... 599).contains(response.statusCode),
              response.body.count <= 65_536,
              Self.mediaType(response.header("Content-Type")) == "application/problem+json",
              (try? StrictJSON.validate(response.body)) != nil,
              let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let type = object["type"] as? String,
              let documentationURL = object["documentation_url"] as? String,
              let title = object["title"] as? String,
              (1 ... 256).contains(title.utf8.count),
              let status = object["status"] as? Int,
              status == response.statusCode,
              let detail = object["detail"] as? String,
              (1 ... 2_048).contains(detail.utf8.count),
              let code = object["code"] as? String,
              code.range(of: "^[a-z][a-z0-9_]{0,62}$", options: .regularExpression) != nil,
              let requestID = object["request_id"] as? String,
              (8 ... 128).contains(requestID.utf8.count),
              response.header("X-Latchway-Request-ID") == nil
                  || response.header("X-Latchway-Request-ID") == requestID,
              let retryable = object["retryable"] as? Bool
        else { return nil }
        let errorCode = LatchwayErrorCode(rawValue: code)
        let canonicalDocumentationURL = errorCode.documentationURL.absoluteString
        guard type == canonicalDocumentationURL,
              documentationURL == canonicalDocumentationURL
        else { return nil }
        let operationIDMemberPresent = object.keys.contains("operation_id")
        let operationID = object["operation_id"] as? String
        guard ProblemWire.hasValidOperationContract(
            code: errorCode,
            status: status,
            retryable: retryable,
            operationID: operationID,
            operationIDMemberPresent: operationIDMemberPresent
        ) else { return nil }
        let retryAfter = (object["retry_after"] as? String).flatMap { value -> Date? in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: value)
        }
        return LatchwayProblem(
            code: errorCode,
            title: title,
            detail: detail,
            status: status,
            requestID: requestID,
            retryable: retryable,
            retryAfter: retryAfter,
            operationID: operationID
        )
    }

    private func validateConfiguration() throws {
        try LatchwayRootKeychainPreflight.validateAccessGroups(
            rootKeychainAccessGroup: configuration.rootKeychainAccessGroup,
            legacySharedKeychainAccessGroups: configuration.legacySharedKeychainAccessGroups
        )
        guard configuration.applicationID.range(
            of: "^app_[0-7][0-9A-HJKMNP-TV-Z]{25}$",
            options: .regularExpression
        ) != nil else {
            throw LatchwayError.invalidConfiguration(
                "applicationID must be the canonical app_ resource ID returned by the Admin API"
            )
        }
        for (label, value) in [("environment", configuration.environment), ("identityProvider", configuration.identityProvider)] {
            guard value.range(of: "^[a-z][a-z0-9_-]{0,62}$", options: .regularExpression) != nil else {
                throw LatchwayError.invalidConfiguration("\(label) must be a valid Latchway identifier")
            }
        }
        guard (1 ... 128).contains(configuration.appVersion.utf8.count) else {
            throw LatchwayError.invalidConfiguration("appVersion must contain 1 to 128 UTF-8 bytes")
        }
        guard (1 ... 128).contains(configuration.clientSDKVersion.utf8.count),
              configuration.clientSDKVersion.range(
                  of: "^[0-9]+\\.[0-9]+\\.[0-9]+(?:-[0-9A-Za-z.-]+)?$",
                  options: .regularExpression
              ) != nil else {
            throw LatchwayError.invalidConfiguration("clientSDKVersion must match the contract version syntax")
        }
        guard configuration.controlRequestTimeout > 0, configuration.controlRequestTimeout <= 120 else {
            throw LatchwayError.invalidConfiguration("controlRequestTimeout must be greater than zero and at most 120 seconds")
        }
        guard let components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else { throw LatchwayError.invalidConfiguration("baseURL must be an absolute URL without credentials, query, or fragment") }
        let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && loopback) else {
            throw LatchwayError.invalidConfiguration("baseURL must use HTTPS except for loopback development")
        }
        guard (try? LatchwayDPoPProofFactory.normalizedHTU(configuration.baseURL)) != nil else {
            throw LatchwayError.invalidConfiguration("baseURL cannot be normalized for DPoP")
        }
    }

    private func ensureRootKeychainPreflight() throws {
        guard !rootKeychainPreflightComplete else { return }
        try rootKeychainPreflight()
        rootKeychainPreflightComplete = true
    }

    private static func mediaType(_ value: String?) -> String? {
        value?
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func validDiagnostics(
        _ remote: ClientDiagnosticsWire,
        active: RuntimeSession,
        thumbprint: String?
    ) -> Bool {
        remote.contractVersion == LatchwayVersion.contract
            && remote.protocolVersion == LatchwayVersion.protocolVersion
            && remote.installation.id == active.installation.id
            && remote.installation.platform == active.installation.platform
            && remote.installation.status == "active"
            && remote.installation.dpopJKT == thumbprint
            && validRootBinding(
                family: remote.installationFamily,
                component: remote.component,
                expectedThumbprint: thumbprint,
                platform: active.installation.platform
            )
            && (active.installationFamily == nil
                || active.installationFamily == remote.installationFamily)
            && (active.component == nil || active.component == remote.component)
            && remote.session.expiresAt > Date(timeIntervalSince1970: 0)
            && (1 ... 128).contains(remote.requestID.utf8.count)
            && (1 ... 128).contains(remote.serverVersion.utf8.count)
    }

    /// Validates optional component-aware root metadata without making it a
    /// requirement for legacy wire-1 grants. Partial metadata fails closed.
    private static func validRootBinding(
        family: LatchwayInstallationFamilySummary?,
        component: LatchwayClientComponentSummary?,
        expectedThumbprint: String?,
        platform: String
    ) -> Bool {
        if family == nil, component == nil { return true }
        guard let family, let component, let expectedThumbprint else { return false }
        return family.id.range(
            of: "^fam_[A-Za-z0-9_-]{16,128}$",
            options: .regularExpression
        ) != nil
            && family.status == "active"
            && component.id.range(
                of: "^cmp_[A-Za-z0-9_-]{16,128}$",
                options: .regularExpression
            ) != nil
            && component.definitionID.range(
                of: "^[a-z][a-z0-9_-]{0,62}$",
                options: .regularExpression
            ) != nil
            && component.kind == "main_app"
            && component.platform == platform
            && component.isRoot
            && component.status == "active"
            && component.dpopJKT == expectedThumbprint
            && !component.grantedFeatures.isEmpty
            && component.grantedFeatures.count <= 256
            && Set(component.grantedFeatures).count == component.grantedFeatures.count
            && component.grantedFeatures.allSatisfy { feature in
                feature.range(
                    of: "^[a-z][a-z0-9_-]{0,62}$",
                    options: .regularExpression
                ) != nil
            }
    }

    private static func validRootTrustBinding(
        _ trust: LatchwayTrustSummary,
        family: LatchwayInstallationFamilySummary?,
        component: LatchwayClientComponentSummary?
    ) -> Bool {
        let providers: Set<String> = [
            "app_attest", "play_integrity", "firebase_app_check", "turnstile", "debug",
        ]
        guard providers.contains(trust.provider),
              trust.parentComponentID == nil,
              trust.parentAttestationProvider == nil,
              trust.delegationID == nil
        else { return false }

        guard let source = trust.source else {
            // Legacy wire-1 grants carried no family/component provenance.
            return family == nil && component == nil
        }
        guard let source = LatchwayComponentTrustSource(rawValue: source) else { return false }
        return switch source {
        case .directAttested:
            ["app_verified", "device_verified", "strong_device_verified"].contains(trust.level)
        case .identityOnly:
            ["none", "identity_only"].contains(trust.level)
        case .webRiskVerified:
            trust.level == "web_risk_verified"
        case .debug:
            trust.level == "debug"
        case .delegatedFromAttestedRoot, .delegatedIdentityOnly, .delegatedDirectAttested:
            false
        }
    }

    private func record(_ error: LatchwayError) async {
        if error.isRevocation {
            session = nil
            try? await sessionStorage.clear()
            terminalError = error
        }
        if error.isRevocation {
            state = .revoked
        } else if let session, session.isUsable(at: await clock.now()) {
            state = .active
        } else if case let .server(problem) = error, problem.code == .sessionExpired {
            state = .expired
        } else {
            state = .failed
        }
        switch error {
        case let .server(problem):
            lastErrorCode = problem.code.description
            lastRequestID = problem.requestID
        default:
            lastErrorCode = error.stableLocalCode
        }
    }
}

private actor LatchwayUnavailableAttestationProvider: LatchwayAttestationProvider {
    func evidence(for challenge: LatchwayAttestationChallenge) async throws -> LatchwayAttestationEvidence {
        throw LatchwayError.attestationUnavailable
    }

    func reset() async throws {}

    func status() async -> LatchwayAttestationStatus {
        LatchwayAttestationStatus(support: .unknown)
    }
}

private extension LatchwayError {
    var requiresAttestedReestablishment: Bool {
        guard case let .server(problem) = self else { return false }
        return [
            .identityReauthenticationRequired,
            .identityTokenExpired,
            .attestationRequired,
            .attestationStale,
            .attestationStepUpRequired,
        ].contains(problem.code)
    }

    var requiresFreshSession: Bool {
        guard case let .server(problem) = self else { return false }
        return [
            .refreshTokenReused,
            .installationRevoked,
            .installationFamilyRevoked,
            .componentRevoked,
            .componentKeyReplaced,
            .sessionRevoked,
            .attestationStale,
            .attestationStepUpRequired,
        ].contains(problem.code)
    }

    var isSafeRefreshRejection: Bool {
        guard case let .server(problem) = self else { return false }
        return problem.code == .sessionExpired
            && problem.status == 401
            && problem.retryable
    }

    var isRevocation: Bool {
        guard case let .server(problem) = self else { return false }
        return [
            .installationRevoked,
            .installationFamilyRevoked,
            .componentRevoked,
            .componentKeyReplaced,
            .sessionRevoked,
        ].contains(problem.code)
    }

    var stableLocalCode: String {
        code
    }
}
