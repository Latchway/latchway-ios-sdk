@preconcurrency import Foundation

private struct LatchwayComponentRuntimeSession: Sendable {
    let accessToken: String
    let expiresAt: Date
    let credential: LatchwayStoredComponentCredential

    func isUsable(at now: Date, leeway: TimeInterval = 30) -> Bool {
        expiresAt.timeIntervalSince(now) > leeway
    }
}

/// A client for an independently executing iOS app extension.
///
/// The extension never receives the containing application's access or refresh
/// token. It can use only its own P-256 key and its own rotating component
/// credential from the component-specific Keychain access group.
public actor LatchwayExtensionClient {
    private let configuration: LatchwayConfiguration
    private let component: LatchwayComponentConfiguration
    private let key: any LatchwayInstallationKey
    private let storage: any LatchwayComponentCredentialStorage
    private let transport: any LatchwayHTTPTransport
    private let clock: any LatchwayClock
    private let proofFactory: LatchwayDPoPProofFactory
    private let controlPlane: LatchwayControlPlane
    private let directAttestationProvider: (any LatchwayAttestationProvider)?

    private var session: LatchwayComponentRuntimeSession?
    private var refreshTask: Task<LatchwayComponentRuntimeSession, Error>?
    private var directAttestationTask: Task<LatchwayComponentRuntimeSession, Error>?

    public init(
        configuration: LatchwayConfiguration,
        component: LatchwayComponentConfiguration,
        directAttestationProvider: (any LatchwayAttestationProvider)? = nil
    ) throws {
        try Self.validate(component)
        let key = LatchwayComponentKeyManager(
            applicationID: configuration.applicationID,
            environment: configuration.environment,
            definitionID: component.definitionID,
            keychainAccessGroup: component.keychainAccessGroup,
            softwareFallbackPolicy: configuration.softwareKeyFallbackPolicy,
            allowCreation: false
        )
        let storage = LatchwayKeychainComponentStorage(
            applicationID: configuration.applicationID,
            environment: configuration.environment,
            definitionID: component.definitionID,
            accessGroup: component.keychainAccessGroup
        )
        let network = LatchwayURLSessionTransport(session: LatchwayURLSessionFactory.make())
        let clock = LatchwaySystemClock()
        let proofFactory = LatchwayDPoPProofFactory(key: key, clock: clock)
        self.configuration = configuration
        self.component = component
        self.key = key
        self.storage = storage
        transport = network
        self.clock = clock
        self.proofFactory = proofFactory
        self.directAttestationProvider = directAttestationProvider
        controlPlane = LatchwayControlPlane(
            configuration: configuration,
            transport: network,
            proofFactory: proofFactory,
            clock: clock
        )
    }

    init(
        configuration: LatchwayConfiguration,
        component: LatchwayComponentConfiguration,
        key: any LatchwayInstallationKey,
        storage: any LatchwayComponentCredentialStorage,
        transport: any LatchwayHTTPTransport,
        clock: any LatchwayClock,
        directAttestationProvider: (any LatchwayAttestationProvider)? = nil
    ) throws {
        try Self.validate(component)
        self.configuration = configuration
        self.component = component
        self.key = key
        self.storage = storage
        self.transport = transport
        self.clock = clock
        self.directAttestationProvider = directAttestationProvider
        proofFactory = LatchwayDPoPProofFactory(key: key, clock: clock)
        controlPlane = LatchwayControlPlane(
            configuration: configuration,
            transport: transport,
            proofFactory: proofFactory,
            clock: clock
        )
    }

    public nonisolated func transport(
        feature: String,
        framework: LatchwayFrameworkMetadata? = nil
    ) -> LatchwayFeatureTransport {
        LatchwayFeatureTransport(
            feature: feature,
            framework: framework,
            baseURL: configuration.baseURL,
            authorize: { [self] request in
                try await authorizedRequest(request, feature: feature, framework: framework)
            },
            send: { [self] request in
                try await send(request, feature: feature, framework: framework)
            },
            streamingRetry: { [self] request, authorized, directive in
                try await authorizedRetryRequest(
                    request,
                    firstAuthorizedRequest: authorized,
                    directive: directive,
                    feature: feature,
                    framework: framework
                )
            }
        )
    }

    public func authorize(_ request: inout URLRequest, feature: String) async throws {
        request = try await authorizedRequest(request, feature: feature, framework: nil)
    }

    public func refresh() async throws {
        _ = try await refreshSession(force: true)
    }

    /// Completes the contract's component-scoped direct App Attest step-up.
    ///
    /// The component's current DPoP session authorizes a one-use version-2
    /// challenge. Successful exchange rotates only this component's session
    /// family and persists its new directly attested refresh credential.
    /// Configure a component-namespaced App Attest provider when constructing
    /// the client; root and sibling accepted-key markers must not be reused.
    /// The stored and returned component platform must exactly match
    /// `configuration.clientRuntime`.
    public func establishDirectAttestation() async throws {
        guard ["action_extension", "sso_extension"]
            .contains(component.kind)
        else {
            throw LatchwayComponentError.invalidConfiguration(
                "This component kind does not support direct App Attest step-up"
            )
        }
        guard let directAttestationProvider else {
            throw LatchwayComponentError.directAttestationRequired
        }
        if let directAttestationTask {
            let value = try await directAttestationTask.value
            session = value
            try Task.checkCancellation()
            return
        }

        let active = try await refreshSession(force: false)
        if let directAttestationTask {
            let value = try await directAttestationTask.value
            session = value
            try Task.checkCancellation()
            return
        }
        if active.credential.trustSource == .delegatedDirectAttested {
            // The operation is a step-up, not an unconditional renewal. Once
            // this component already holds usable composite trust, avoid
            // consuming another one-use challenge or rotating its session.
            return
        }
        if active.credential.trustSource != .delegatedDirectAttested,
           session?.credential.trustSource == .delegatedDirectAttested {
            // A concurrent caller completed the same step-up while this caller
            // was waiting for the shared component-session refresh.
            return
        }
        let task = Task {
            try await Self.performDirectAttestation(
                active: active,
                provider: directAttestationProvider,
                controlPlane: controlPlane,
                storage: storage,
                clock: clock,
                expectedPlatform: configuration.clientRuntime.platformIdentifier
            )
        }
        directAttestationTask = task
        defer { directAttestationTask = nil }
        do {
            let value = try await task.value
            session = value
            try Task.checkCancellation()
        } catch is CancellationError {
            throw LatchwayError.cancelled
        } catch let error as LatchwayComponentError {
            throw error
        } catch let error as LatchwayError {
            if error == .keyStorageFailure { session = nil }
            throw Self.map(error)
        } catch {
            throw LatchwayError.transportFailure
        }
    }

    public func diagnostics() async -> LatchwayComponentDiagnostics {
        let credential = try? await storage.load()
        let now = await clock.now()
        let thumbprint = try? await proofFactory.thumbprint()
        let usable = credential.flatMap { credential in
            thumbprint.map { thumbprint in
                credential.isValid(
                    for: component,
                    keyThumbprint: thumbprint,
                    now: now,
                    expectedPlatform: configuration.clientRuntime.platformIdentifier
                )
            }
        } ?? false
        let keyStorage = await key.storage()
        return LatchwayComponentDiagnostics(
            familyID: credential?.family.id,
            componentID: credential?.component.id,
            definitionID: component.definitionID,
            keychainAccessGroup: component.keychainAccessGroup,
            keyAvailable: keyStorage != .unavailable,
            keyStorage: keyStorage,
            grantAvailable: usable,
            sessionAvailable: session?.isUsable(at: now) == true,
            trustSource: credential?.trustSource,
            trustExpiresAt: credential?.trustExpiresAt,
            containingAppActionRequired: !usable
        )
    }

    private func authorizedRequest(
        _ request: URLRequest,
        feature: String,
        framework: LatchwayFrameworkMetadata?
    ) async throws -> URLRequest {
        guard !Task.isCancelled else { throw LatchwayError.cancelled }
        try Self.validateFeature(feature)
        var authorized = request
        try LatchwayComponentRequestSecurity.prepare(
            &authorized,
            configuration: configuration,
            feature: feature,
            framework: framework,
            allowManagedPlaceholder: framework != nil
        )
        let active = try await activeSession(feature: feature)
        guard !Task.isCancelled else { throw LatchwayError.cancelled }
        guard let url = authorized.url else { throw LatchwayError.invalidServerResponse }
        let proof = try await proofFactory.proof(
            method: authorized.httpMethod?.uppercased() ?? "GET",
            url: url,
            accessToken: active.accessToken
        )
        guard !Task.isCancelled else { throw LatchwayError.cancelled }
        authorized.setValue("DPoP \(active.accessToken)", forHTTPHeaderField: "Authorization")
        authorized.setValue(proof, forHTTPHeaderField: "DPoP")
        authorized.setValue(feature, forHTTPHeaderField: "X-Latchway-Feature")
        LatchwayComponentRequestSecurity.addMetadata(
            to: &authorized,
            configuration: configuration,
            framework: framework
        )
        return authorized
    }

    private func send(
        _ request: URLRequest,
        feature: String,
        framework: LatchwayFrameworkMetadata?
    ) async throws -> LatchwayHTTPResponse {
        guard !Task.isCancelled else { throw LatchwayError.cancelled }
        let first = try await authorizedRequest(request, feature: feature, framework: framework)
        let firstResponse = try await transport.send(first)
        guard !Task.isCancelled else { throw LatchwayError.cancelled }
        guard !(300 ... 399).contains(firstResponse.statusCode) else {
            throw LatchwayError.invalidServerResponse
        }
        guard (400 ... 599).contains(firstResponse.statusCode) else { return firstResponse }
        let retry = try await authorizedRetryRequest(
            request,
            firstAuthorizedRequest: first,
            response: firstResponse,
            feature: feature,
            framework: framework
        )
        let response = try await transport.send(retry)
        guard !Task.isCancelled else { throw LatchwayError.cancelled }
        guard !(300 ... 399).contains(response.statusCode) else {
            throw LatchwayError.invalidServerResponse
        }
        if (400 ... 599).contains(response.statusCode) {
            guard let problem = LatchwayClient.problem(from: response) else {
                throw LatchwayError.invalidServerResponse
            }
            throw Self.map(.server(problem))
        }
        return response
    }

    private func authorizedRetryRequest(
        _ request: URLRequest,
        firstAuthorizedRequest: URLRequest,
        response: LatchwayHTTPResponse,
        feature: String,
        framework: LatchwayFrameworkMetadata?
    ) async throws -> URLRequest {
        guard let problem = LatchwayClient.problem(from: response) else {
            throw LatchwayError.invalidServerResponse
        }
        guard request.httpBodyStream == nil,
              let directive = SafeRetryDirective.parse(
                  response: response,
                  expectedRequestID: firstAuthorizedRequest.value(
                      forHTTPHeaderField: "X-Latchway-Request-ID"
                  )
              )
        else { throw Self.map(.server(problem)) }

        return try await authorizedRetryRequest(
            request,
            firstAuthorizedRequest: firstAuthorizedRequest,
            directive: directive,
            feature: feature,
            framework: framework
        )
    }

    private func authorizedRetryRequest(
        _ request: URLRequest,
        firstAuthorizedRequest: URLRequest,
        directive: SafeRetryDirective,
        feature: String,
        framework: LatchwayFrameworkMetadata?
    ) async throws -> URLRequest {
        var retry = request
        retry.setValue(
            firstAuthorizedRequest.value(forHTTPHeaderField: "X-Latchway-Request-ID"),
            forHTTPHeaderField: "X-Latchway-Request-ID"
        )
        let active: LatchwayComponentRuntimeSession
        let nonce: String?
        switch directive {
        case .sessionExpired:
            active = try await refreshSession(force: true)
            nonce = nil
        case let .dpopNonceRequired(value):
            active = try await activeSession(feature: feature)
            nonce = value
        }
        try LatchwayComponentRequestSecurity.prepare(
            &retry,
            configuration: configuration,
            feature: feature,
            framework: framework,
            allowManagedPlaceholder: framework != nil
        )
        guard let url = retry.url else {
            throw LatchwayError.invalidRequest("URLRequest must contain a URL")
        }
        let proof = try await proofFactory.proof(
            method: retry.httpMethod?.uppercased() ?? "GET",
            url: url,
            accessToken: active.accessToken,
            nonce: nonce
        )
        retry.setValue("DPoP \(active.accessToken)", forHTTPHeaderField: "Authorization")
        retry.setValue(proof, forHTTPHeaderField: "DPoP")
        retry.setValue(feature, forHTTPHeaderField: "X-Latchway-Feature")
        LatchwayComponentRequestSecurity.addMetadata(
            to: &retry,
            configuration: configuration,
            framework: framework
        )
        return retry
    }

    private func activeSession(feature: String) async throws -> LatchwayComponentRuntimeSession {
        if let session, session.isUsable(at: await clock.now()) {
            guard session.credential.component.grantedFeatures.contains(feature) else {
                throw LatchwayComponentError.featureNotDelegated
            }
            return session
        }
        let refreshed = try await refreshSession(force: true)
        guard refreshed.credential.component.grantedFeatures.contains(feature) else {
            throw LatchwayComponentError.featureNotDelegated
        }
        return refreshed
    }

    private static func performDirectAttestation(
        active: LatchwayComponentRuntimeSession,
        provider: any LatchwayAttestationProvider,
        controlPlane: LatchwayControlPlane,
        storage: any LatchwayComponentCredentialStorage,
        clock: any LatchwayClock,
        expectedPlatform: String
    ) async throws -> LatchwayComponentRuntimeSession {
        try Task.checkCancellation()
        let componentID = active.credential.component.id
        let challenge = try await controlPlane.createComponentAttestationChallenge(
            componentID: componentID,
            accessToken: active.accessToken
        )
        let now = await clock.now()
        let issuedAt = Date(timeIntervalSince1970: TimeInterval(challenge.issuedAt))
        let challengeTTL = challenge.expiresAt.timeIntervalSince(issuedAt)
        guard challenge.bindingVersion == 2,
              challenge.challengeID.range(
                  of: "^chl_[A-Za-z0-9_-]{16,128}$",
                  options: .regularExpression
              ) != nil,
              (43 ... 86).contains(challenge.challengeNonce.utf8.count),
              let nonce = try? Base64URL.decode(challenge.challengeNonce),
              (32 ... 64).contains(nonce.count),
              challenge.issuedAt >= 0,
              issuedAt <= now.addingTimeInterval(300),
              challengeTTL > 0,
              challenge.expiresAt > now,
              challenge.attestation.provider == "app_attest",
              challenge.attestation.mode == "required",
              challenge.attestation.clientDataHash.utf8.count == 43,
              let clientDataHash = try? Base64URL.decode(
                  challenge.attestation.clientDataHash
              ),
              clientDataHash.count == 32
        else { throw LatchwayError.invalidAttestationBinding }

        let publicChallenge = LatchwayAttestationChallenge(
            id: challenge.challengeID,
            provider: challenge.attestation.provider,
            clientDataHash: clientDataHash,
            expiresAt: challenge.expiresAt,
            options: challenge.attestation.providerOptions ?? [:]
        )
        let evidence = try await provider.evidence(for: publicChallenge)
        guard evidence.provider == "app_attest" else {
            throw LatchwayError.attestationUnavailable
        }
        let grant = try await controlPlane.exchangeComponentAttestation(
            componentID: componentID,
            challengeID: challenge.challengeID,
            evidence: evidence,
            accessToken: active.accessToken
        )
        let accepted = try acceptDirectAttestation(
            grant,
            replacing: active.credential,
            issuedAt: await clock.now(),
            expectedPlatform: expectedPlatform
        )
        do {
            try await storage.save(accepted.credential)
        } catch {
            // A successful exchange revokes the delegated-only session family.
            // Never leave its stale refresh credential looking recoverable.
            try? await storage.clear()
            throw LatchwayError.keyStorageFailure
        }
        await provider.didAccept(evidence)
        return accepted
    }

    private static func acceptDirectAttestation(
        _ grant: SessionGrantWire,
        replacing stored: LatchwayStoredComponentCredential,
        issuedAt: Date,
        expectedPlatform: String
    ) throws -> LatchwayComponentRuntimeSession {
        let refreshExpiration = issuedAt.addingTimeInterval(
            TimeInterval(grant.refreshExpiresIn)
        )
        guard grant.tokenType == "DPoP",
              (60 ... 3_600).contains(grant.expiresIn),
              (300 ... 2_592_300).contains(grant.refreshExpiresIn),
              (64 ... 16_384).contains(grant.accessToken.utf8.count),
              (32 ... 2_048).contains(grant.refreshToken.utf8.count),
              grant.refreshToken.rangeOfCharacter(
                  from: CharacterSet(charactersIn: "\r\n\0")
              ) == nil,
              stored.kind == .sessionRefreshToken,
              stored.trustSource == .delegatedFromAttestedRoot,
              validInstallation(grant.installation, replacing: stored, required: true),
              validFamily(grant.installationFamily, replacing: stored.family, required: true),
              validComponent(
                  grant.component,
                  replacing: stored.component,
                  expectedPlatform: expectedPlatform,
                  required: true
              ),
              validDirectTrust(grant.trust, replacing: stored, issuedAt: issuedAt),
              refreshExpiration <= grant.trust.expiresAt,
              let family = grant.installationFamily,
              let component = grant.component
        else { throw LatchwayError.invalidServerResponse }

        let updated = LatchwayStoredComponentCredential(
            family: family,
            component: component,
            requestedFeatures: stored.requestedFeatures,
            trustSource: .delegatedDirectAttested,
            trustExpiresAt: grant.trust.expiresAt,
            keyThumbprint: stored.keyThumbprint,
            rotationToken: grant.refreshToken,
            rotationExpiresAt: refreshExpiration,
            kind: .sessionRefreshToken
        )
        return LatchwayComponentRuntimeSession(
            accessToken: grant.accessToken,
            expiresAt: issuedAt.addingTimeInterval(TimeInterval(grant.expiresIn)),
            credential: updated
        )
    }

    private static func validDirectTrust(
        _ trust: LatchwayTrustSummary,
        replacing stored: LatchwayStoredComponentCredential,
        issuedAt: Date
    ) -> Bool {
        trust.provider == "app_attest"
            && trust.level == "app_verified"
            && trust.source == LatchwayComponentTrustSource.delegatedDirectAttested.rawValue
            && trust.verifiedAt > Date(timeIntervalSince1970: 0)
            && trust.verifiedAt <= issuedAt.addingTimeInterval(300)
            && trust.expiresAt > issuedAt
            && trust.expiresAt <= stored.trustExpiresAt
            && trust.parentComponentID?.range(
                of: "^cmp_[A-Za-z0-9_-]{16,128}$",
                options: .regularExpression
            ) != nil
            && trust.parentAttestationProvider == "app_attest"
            && trust.delegationID?.range(
                of: "^dlg_[A-Za-z0-9_-]{16,128}$",
                options: .regularExpression
            ) != nil
    }

    private func refreshSession(force: Bool) async throws -> LatchwayComponentRuntimeSession {
        guard !Task.isCancelled else { throw LatchwayError.cancelled }
        if !force, let session, session.isUsable(at: await clock.now()) { return session }
        if let refreshTask {
            do {
                let value = try await refreshTask.value
                session = value
                try Task.checkCancellation()
                return value
            } catch is CancellationError {
                throw LatchwayError.cancelled
            }
        }
        let expectedPlatform = configuration.clientRuntime.platformIdentifier
        let task = Task { [controlPlane, proofFactory, storage, component, clock, expectedPlatform] in
            // Loading the shared credential belongs inside the single-flight
            // task.  Keychain reads suspend, so performing one before publishing
            // refreshTask would let concurrent extension requests each consume
            // the same one-time provisioning grant.
            let stored: LatchwayStoredComponentCredential
            do {
                guard let value = try await storage.load() else {
                    throw LatchwayComponentError.containingAppSetupRequired
                }
                stored = value
            } catch let error as LatchwayComponentError {
                throw error
            } catch {
                throw LatchwayComponentError.keychainAccessGroupUnavailable
            }
            let now = await clock.now()
            let thumbprint = try await proofFactory.thumbprint()
            guard stored.component.definitionID == component.definitionID,
                  stored.component.kind == component.kind,
                  stored.component.platform == expectedPlatform,
                  stored.component.status == "active",
                  stored.family.status == "active",
                  stored.keyThumbprint == thumbprint,
                  stored.component.dpopJKT == thumbprint
            else { throw LatchwayComponentError.componentKeyUnavailable }
            guard stored.trustExpiresAt > now else {
                throw LatchwayComponentError.parentTrustExpired
            }
            guard stored.rotationExpiresAt > now else {
                throw LatchwayComponentError.componentGrantExpired
            }
            guard stored.isValid(
                for: component,
                keyThumbprint: thumbprint,
                now: now,
                expectedPlatform: expectedPlatform
            ) else {
                throw LatchwayComponentError.componentNotProvisioned
            }

            let grant: ComponentSessionGrantWire
            do {
                switch stored.kind {
                case .provisioningGrant:
                    grant = try await controlPlane.createComponentSession(
                        componentID: stored.component.id,
                        refreshGrant: stored.rotationToken
                    )
                case .sessionRefreshToken:
                    grant = try await controlPlane.refreshComponent(
                        refreshToken: stored.rotationToken
                    )
                }
            } catch let error as LatchwayError {
                throw Self.map(error)
            }
            let accepted = try Self.accept(
                grant,
                replacing: stored,
                issuedAt: await clock.now(),
                expectedPlatform: expectedPlatform
            )
            do {
                try await storage.save(accepted.credential)
            } catch {
                if stored.kind == .provisioningGrant {
                    // Initial provisioning grants are one-time exchanges, not
                    // ADR-0024 rotations. Never leave a consumed grant looking
                    // usable; the containing app must provision it again.
                    try? await storage.clear()
                }
                // For an ordinary component refresh, the old value remains in
                // storage so an exact same-key duplicate can recover the cached
                // rotation result within the server's 30-second window.
                throw LatchwayError.keyStorageFailure
            }
            return accepted
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let value = try await task.value
            session = value
            try Task.checkCancellation()
            return value
        } catch let error as LatchwayComponentError {
            if error == .componentRevoked || error == .installationFamilyRevoked {
                session = nil
                try? await storage.clear()
            }
            throw error
        } catch let error as LatchwayError {
            throw error
        } catch is CancellationError {
            throw LatchwayError.cancelled
        } catch {
            throw LatchwayError.transportFailure
        }
    }

    private static func accept(
        _ grant: ComponentSessionGrantWire,
        replacing stored: LatchwayStoredComponentCredential,
        issuedAt: Date,
        expectedPlatform: String
    ) throws -> LatchwayComponentRuntimeSession {
        let refreshExpiration: Date
        if let absolute = grant.refreshExpiresAt {
            refreshExpiration = absolute
        } else if let seconds = grant.refreshExpiresIn {
            refreshExpiration = issuedAt.addingTimeInterval(TimeInterval(seconds))
        } else {
            throw LatchwayError.invalidServerResponse
        }
        guard grant.tokenType == nil || grant.tokenType == "DPoP",
              (60 ... 3_600).contains(grant.expiresIn),
              (64 ... 16_384).contains(grant.accessToken.utf8.count),
              (32 ... 2_048).contains(grant.refreshToken.utf8.count),
              refreshExpiration.timeIntervalSince(issuedAt) >= 300,
              refreshExpiration.timeIntervalSince(issuedAt) <= 2_592_300,
              Self.validInstallation(
                  grant.installation,
                  replacing: stored,
                  required: stored.kind == .sessionRefreshToken
              ),
              Self.validFamily(
                  grant.installationFamily,
                  replacing: stored.family,
                  required: stored.kind == .sessionRefreshToken
              ),
              Self.validComponent(
                  grant.component,
                  replacing: stored.component,
                  expectedPlatform: expectedPlatform,
                  required: stored.kind == .sessionRefreshToken
              ),
              Self.validTrust(
                  grant.trust,
                  replacing: stored,
                  issuedAt: issuedAt,
                  required: stored.kind == .sessionRefreshToken
              )
        else { throw LatchwayError.invalidServerResponse }

        let trustExpiration = min(grant.trust?.expiresAt ?? stored.trustExpiresAt, stored.trustExpiresAt)
        let updated = LatchwayStoredComponentCredential(
            family: grant.installationFamily ?? stored.family,
            component: grant.component ?? stored.component,
            requestedFeatures: stored.requestedFeatures,
            trustSource: grant.trust?.source.flatMap(LatchwayComponentTrustSource.init(rawValue:))
                ?? stored.trustSource,
            trustExpiresAt: trustExpiration,
            keyThumbprint: stored.keyThumbprint,
            rotationToken: grant.refreshToken,
            rotationExpiresAt: refreshExpiration,
            kind: .sessionRefreshToken
        )
        return LatchwayComponentRuntimeSession(
            accessToken: grant.accessToken,
            expiresAt: issuedAt.addingTimeInterval(TimeInterval(grant.expiresIn)),
            credential: updated
        )
    }

    private static func validInstallation(
        _ installation: LatchwayInstallationSummary?,
        replacing stored: LatchwayStoredComponentCredential,
        required: Bool
    ) -> Bool {
        guard let installation else { return !required }
        return installation.id.range(
            of: "^ins_[A-Za-z0-9_-]{16,128}$",
            options: .regularExpression
        ) != nil
            && installation.platform == stored.component.platform
            && installation.status == "active"
            && installation.dpopJKT == stored.keyThumbprint
    }

    private static func validFamily(
        _ family: LatchwayInstallationFamilySummary?,
        replacing stored: LatchwayInstallationFamilySummary,
        required: Bool
    ) -> Bool {
        guard let family else { return !required }
        return family.id == stored.id && family.status == "active"
    }

    private static func validComponent(
        _ component: LatchwayClientComponentSummary?,
        replacing stored: LatchwayClientComponentSummary,
        expectedPlatform: String,
        required: Bool
    ) -> Bool {
        guard let component else { return !required }
        return component.id == stored.id
            && component.definitionID == stored.definitionID
            && component.kind == stored.kind
            && component.platform == expectedPlatform
            && !component.isRoot
            && component.dpopJKT == stored.dpopJKT
            && component.status == "active"
            && !component.grantedFeatures.isEmpty
            && Set(component.grantedFeatures) == Set(stored.grantedFeatures)
            && Set(component.grantedFeatures).count == component.grantedFeatures.count
    }

    private static func validTrust(
        _ trust: LatchwayTrustSummary?,
        replacing stored: LatchwayStoredComponentCredential,
        issuedAt: Date,
        required: Bool
    ) -> Bool {
        guard let trust else { return !required }
        let levels: Set<String> = [
            "none", "identity_only", "web_risk_verified", "app_verified",
            "device_verified", "strong_device_verified", "debug",
        ]
        let providers: Set<String> = [
            "app_attest", "play_integrity", "firebase_app_check", "turnstile", "debug",
        ]
        guard providers.contains(trust.provider),
              levels.contains(trust.level),
              trust.verifiedAt > Date(timeIntervalSince1970: 0),
              trust.verifiedAt <= issuedAt.addingTimeInterval(300),
              trust.expiresAt > issuedAt,
              trust.expiresAt <= stored.trustExpiresAt,
              trust.source == stored.trustSource.rawValue,
              trust.parentComponentID?.range(
                  of: "^cmp_[A-Za-z0-9_-]{16,128}$",
                  options: .regularExpression
              ) != nil,
              trust.delegationID?.range(
                  of: "^dlg_[A-Za-z0-9_-]{16,128}$",
                  options: .regularExpression
              ) != nil,
              trust.parentAttestationProvider.map(providers.contains) ?? true
        else { return false }
        return true
    }

    private static func validate(_ component: LatchwayComponentConfiguration) throws {
        guard component.definitionID.range(
            of: "^[a-z][a-z0-9_-]{0,62}$",
            options: .regularExpression
        ) != nil,
        component.kind.range(of: "^[a-z][a-z0-9_-]{0,62}$", options: .regularExpression) != nil,
        component.keychainAccessGroup.range(
            of: "^[A-Za-z0-9._-]{1,255}$",
            options: .regularExpression
        ) != nil,
        !component.requestedFeatures.isEmpty,
        component.requestedFeatures.count <= 256,
        Set(component.requestedFeatures).count == component.requestedFeatures.count,
        component.requestedFeatures.allSatisfy({ feature in
            feature.range(of: "^[a-z][a-z0-9_-]{0,62}$", options: .regularExpression) != nil
        }) else {
            throw LatchwayComponentError.invalidConfiguration("The component descriptor is invalid")
        }
    }

    private static func validateFeature(_ feature: String) throws {
        guard feature.range(of: "^[a-z][a-z0-9_-]{0,62}$", options: .regularExpression) != nil else {
            throw LatchwayError.invalidRequest("feature must be a valid Latchway identifier")
        }
    }

    private static func map(_ error: LatchwayError) -> Error {
        guard case let .server(problem) = error else { return error }
        return switch problem.code {
        case .containingAppSetupRequired: LatchwayComponentError.containingAppSetupRequired
        case .componentDefinitionNotFound, .componentNotConfigured, .componentNotProvisioned:
            LatchwayComponentError.componentNotProvisioned
        case .componentRevoked, .componentKeyReplaced, .sessionRevoked, .refreshTokenReused:
            LatchwayComponentError.componentRevoked
        case .componentKeyInvalid: LatchwayComponentError.componentKeyUnavailable
        case .installationRevoked, .installationFamilyRevoked, .installationFamilyNotFound:
            LatchwayComponentError.installationFamilyRevoked
        case .componentParentTrustExpired, .componentDelegationExpired:
            LatchwayComponentError.parentTrustExpired
        case .componentFeatureNotGranted: LatchwayComponentError.featureNotDelegated
        case .componentDirectAttestationRequired, .attestationStepUpRequired:
            LatchwayComponentError.directAttestationRequired
        case .identityReauthenticationRequired, .identityTokenExpired, .identityTokenInvalid:
            LatchwayComponentError.identityChanged
        default: error
        }
    }
}
