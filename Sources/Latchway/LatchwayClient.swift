@preconcurrency import Foundation

public actor LatchwayClient {
    private let configuration: LatchwayConfiguration
    private let identityTokenProvider: any LatchwayIdentityTokenProvider
    private let attestationProvider: any LatchwayAttestationProvider
    private let installationKey: any LatchwayInstallationKey
    private let sessionStorage: any LatchwaySessionStorage
    private let transport: any LatchwayHTTPTransport
    private let clock: any LatchwayClock
    private let proofFactory: LatchwayDPoPProofFactory
    private let controlPlane: LatchwayControlPlane

    private var session: RuntimeSession?
    private var establishmentTask: Task<RuntimeSession, Error>?
    private var refreshTask: Task<RuntimeSession, Error>?
    private var state: LatchwayDiagnostics.SessionState = .absent
    private var lastRequestID: String?
    private var lastErrorCode: String?
    private var serverVersion: String?
    private var terminalError: LatchwayError?

    public init(
        configuration: LatchwayConfiguration,
        identityTokenProvider: any LatchwayIdentityTokenProvider
    ) {
        let key = LatchwayInstallationKeyManager(
            applicationID: configuration.applicationID,
            environment: configuration.environment,
            clientRuntime: configuration.clientRuntime,
            softwareFallbackPolicy: configuration.softwareKeyFallbackPolicy
        )
        let storage = LatchwayKeychainSessionStorage(
            applicationID: configuration.applicationID,
            environment: configuration.environment,
            clientRuntime: configuration.clientRuntime
        )
        let transport = LatchwayURLSessionTransport(session: LatchwayURLSessionFactory.make())
        let clock = LatchwaySystemClock()
        let attestation = configuration.attestationProvider ?? LatchwayUnavailableAttestationProvider()
        let proofFactory = LatchwayDPoPProofFactory(key: key, clock: clock)

        self.configuration = configuration
        self.identityTokenProvider = identityTokenProvider
        self.attestationProvider = attestation
        self.installationKey = key
        self.sessionStorage = storage
        self.transport = transport
        self.clock = clock
        self.proofFactory = proofFactory
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
        self.configuration = configuration
        self.identityTokenProvider = identityTokenProvider
        self.attestationProvider = attestationProvider
        self.installationKey = installationKey
        self.sessionStorage = sessionStorage
        self.transport = transport
        self.clock = clock
        self.proofFactory = proofFactory
        self.controlPlane = LatchwayControlPlane(
            configuration: configuration,
            transport: transport,
            proofFactory: proofFactory,
            clock: clock
        )
    }

    public func authorize(_ request: inout URLRequest, feature: String) async throws {
        try await authorize(&request, feature: feature, dpopNonce: nil)
    }

    /// Authorizes a request using a nonce supplied by a validated, same-origin
    /// `dpop_nonce_required` response.
    ///
    /// This overload exists for transports such as React Native fetch where
    /// the caller, rather than ``send(_:feature:)``, owns network dispatch.
    /// A nonce is opaque and non-secret, but is still length checked before it
    /// is included in a signed proof.
    public func authorize(
        _ request: inout URLRequest,
        feature: String,
        nonce: String
    ) async throws {
        guard (16 ... 512).contains(nonce.utf8.count) else {
            throw LatchwayError.invalidRequest("DPoP nonce must contain 16 to 512 UTF-8 bytes")
        }
        try await authorize(&request, feature: feature, dpopNonce: nonce)
    }

    /// Forces one single-flight session refresh without exposing session
    /// credentials. This is intended for caller-owned transports after a
    /// validated, same-origin `session_expired` rejection.
    public func refresh() async throws {
        try validateConfiguration()
        _ = try await refreshSession(force: true)
    }

    private func authorize(
        _ request: inout URLRequest,
        feature: String,
        dpopNonce: String?
    ) async throws {
        guard !Task.isCancelled else { throw LatchwayError.cancelled }
        try validateConfiguration()
        try validateFeature(feature)
        guard let url = request.url else { throw LatchwayError.invalidRequest("URLRequest must contain a URL") }
        try validateGatewayURL(url)
        let method = request.httpMethod?.uppercased() ?? "GET"
        try validateNoUpstreamCredential(in: request)

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
        request.setValue(configuration.clientRuntime.sdkIdentifier, forHTTPHeaderField: "X-Latchway-SDK")
        request.setValue(configuration.clientSDKVersion, forHTTPHeaderField: "X-Latchway-SDK-Version")
        request.setValue(String(LatchwayVersion.protocolVersion), forHTTPHeaderField: "X-Latchway-Protocol-Version")
        if request.value(forHTTPHeaderField: "X-Latchway-Request-ID") == nil {
            request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Latchway-Request-ID")
        }
    }

    /// Authorizes and sends a buffered request through the configured transport.
    ///
    /// This method retries at most once, and only for `session_expired` or
    /// `dpop_nonce_required`, which the wire contract defines as rejection
    /// before upstream dispatch. Requests backed by an `httpBodyStream` are
    /// never replayed. Streaming callers should call ``authorize(_:feature:)``
    /// and consume `bytes(for:)` from ``makeURLSession()`` directly.
    public func send(_ request: URLRequest, feature: String) async throws -> LatchwayHTTPResponse {
        var firstRequest = request
        try await authorize(&firstRequest, feature: feature)
        let firstResponse = try await sendThroughTransport(firstRequest)
        guard (400 ... 599).contains(firstResponse.statusCode) else { return firstResponse }
        guard let firstProblem = Self.problem(from: firstResponse) else {
            let error = LatchwayError.invalidServerResponse
            await record(error)
            throw error
        }
        guard request.httpBodyStream == nil else {
            let error = LatchwayError.server(firstProblem)
            await record(error)
            throw error
        }

        var retryRequest = request
        retryRequest.setValue(
            firstRequest.value(forHTTPHeaderField: "X-Latchway-Request-ID"),
            forHTTPHeaderField: "X-Latchway-Request-ID"
        )
        switch firstProblem.code {
        case .sessionExpired where firstProblem.status == 401 && firstProblem.retryable:
            let refreshed = try await refreshSession(force: true)
            try await applyAuthorization(&retryRequest, feature: feature, active: refreshed, nonce: nil)
        case .dpopNonceRequired where firstProblem.status == 401 && firstProblem.retryable:
            guard let nonce = firstResponse.header("DPoP-Nonce"), (16 ... 512).contains(nonce.utf8.count) else {
                let error = LatchwayError.server(firstProblem)
                await record(error)
                throw error
            }
            let active = try await activeSession()
            try await applyAuthorization(&retryRequest, feature: feature, active: active, nonce: nonce)
        default:
            let error = LatchwayError.server(firstProblem)
            await record(error)
            throw error
        }

        let secondResponse = try await sendThroughTransport(retryRequest)
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

    public func diagnostics() async -> LatchwayDiagnostics {
        let keyStorage = await installationKey.storage()
        let thumbprint = try? await proofFactory.thumbprint()
        let attestation = await attestationProvider.status()
        var installationID = session?.installation.id
        var expiration = session?.expiresAt

        if let active = session,
           active.isUsable(at: await clock.now()),
           let remote = try? await controlPlane.diagnostics(accessToken: active.accessToken),
           Self.validDiagnostics(remote, active: active, thumbprint: thumbprint) {
            serverVersion = remote.serverVersion
            lastRequestID = remote.requestID
            installationID = remote.installation.id
            expiration = remote.session.expiresAt
        }
        return LatchwayDiagnostics(
            sdkVersion: configuration.clientSDKVersion,
            keyStorage: keyStorage,
            keyThumbprint: thumbprint,
            attestation: attestation,
            sessionState: state,
            sessionExpiresAt: expiration,
            installationID: installationID,
            serverVersion: serverVersion,
            lastRequestID: lastRequestID,
            lastErrorCode: lastErrorCode
        )
    }

    private func activeSession() async throws -> RuntimeSession {
        try validateConfiguration()
        if state == .revoked { throw terminalError ?? LatchwayError.sessionUnavailable }
        if let session, session.isUsable(at: await clock.now()) {
            state = .active
            return session
        }
        if refreshTask != nil { return try await refreshSession(force: true) }
        if establishmentTask != nil { return try await establishSession() }

        if session != nil { return try await refreshSession(force: true) }
        do {
            if let stored = try await sessionStorage.load(), stored.refreshExpiresAt > (await clock.now()) {
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
            guard evidence.provider == challenge.attestation.provider else { throw LatchwayError.attestationUnavailable }
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
                installation: session.installation
            )
        } else if let loaded = try await sessionStorage.load() {
            stored = loaded
        } else {
            return try await establishSession()
        }
        return try await refreshStoredSession(stored)
    }

    private func refreshStoredSession(_ stored: LatchwayStoredSession) async throws -> RuntimeSession {
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
              stored.installation.dpopJKT == expectedThumbprint
        else {
            await clearSession()
            return try await establishSession()
        }
        if let refreshTask { return try await resolve(refreshTask, kind: .refreshing) }
        state = .refreshing
        let task = Task { [controlPlane, identityTokenProvider, proofFactory, sessionStorage, configuration, clock] in
            let grant: SessionGrantWire
            do {
                grant = try await controlPlane.refresh(refreshToken: stored.refreshToken)
            } catch let error as LatchwayError where error.requiresIdentityReauthentication {
                let identityToken = try await identityTokenProvider.identityToken()
                guard (16 ... 65_536).contains(identityToken.utf8.count) else {
                    throw LatchwayError.invalidRequest("The identity token has an invalid length")
                }
                grant = try await controlPlane.refresh(refreshToken: stored.refreshToken, identityToken: identityToken)
            }
            let expectedThumbprint = try await proofFactory.thumbprint()
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
                // The server may already have consumed and rotated the refresh
                // token. Discard every local copy so it can never be replayed.
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
            trust: grant.trust
        )
        do {
            try await storage.save(LatchwayStoredSession(
                refreshToken: runtime.refreshToken,
                refreshExpiresAt: runtime.refreshExpiresAt,
                installation: runtime.installation
            ))
        } catch {
            // A failed write after refresh must not leave the previously
            // rotated token available for accidental reuse.
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
        nonce: String?
    ) async throws {
        try validateFeature(feature)
        guard let url = request.url else { throw LatchwayError.invalidRequest("URLRequest must contain a URL") }
        try validateGatewayURL(url)
        try validateNoUpstreamCredential(in: request)
        guard !Task.isCancelled else { throw LatchwayError.cancelled }
        let method = request.httpMethod?.uppercased() ?? "GET"
        let proof = try await proofFactory.proof(method: method, url: url, accessToken: active.accessToken, nonce: nonce)
        guard !Task.isCancelled else { throw LatchwayError.cancelled }
        request.setValue("DPoP \(active.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(proof, forHTTPHeaderField: "DPoP")
        request.setValue(feature, forHTTPHeaderField: "X-Latchway-Feature")
        request.setValue(configuration.clientRuntime.sdkIdentifier, forHTTPHeaderField: "X-Latchway-SDK")
        request.setValue(configuration.clientSDKVersion, forHTTPHeaderField: "X-Latchway-SDK-Version")
        request.setValue(String(LatchwayVersion.protocolVersion), forHTTPHeaderField: "X-Latchway-Protocol-Version")
        if request.value(forHTTPHeaderField: "X-Latchway-Request-ID") == nil {
            request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Latchway-Request-ID")
        }
    }

    private static func problem(from response: LatchwayHTTPResponse) -> LatchwayProblem? {
        guard (400 ... 599).contains(response.statusCode),
              response.body.count <= 65_536,
              Self.mediaType(response.header("Content-Type")) == "application/problem+json",
              (try? StrictJSON.validate(response.body)) != nil,
              let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let type = object["type"] as? String,
              let typeURL = URL(string: type),
              typeURL.scheme != nil,
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

    private func validateGatewayURL(_ url: URL) throws {
        guard let request = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let gateway = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false),
              request.scheme?.lowercased() == gateway.scheme?.lowercased(),
              request.host?.lowercased() == gateway.host?.lowercased(),
              Self.effectivePort(request) == Self.effectivePort(gateway),
              request.user == nil,
              request.password == nil,
              Self.isWithinGatewayPath(
                  try Self.normalizedPath(url),
                  basePath: try Self.normalizedPath(configuration.baseURL)
              )
        else { throw LatchwayError.invalidRequest("Requests may only be authorized for the configured Latchway origin") }
    }

    private func validateConfiguration() throws {
        guard (1 ... 128).contains(configuration.applicationID.utf8.count) else {
            throw LatchwayError.invalidConfiguration("applicationID must contain 1 to 128 UTF-8 bytes")
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

    private func validateNoUpstreamCredential(in request: URLRequest) throws {
        if let requestID = request.value(forHTTPHeaderField: "X-Latchway-Request-ID") {
            guard requestID.utf8.count >= 8,
                  requestID.utf8.count <= 128,
                  requestID.range(
                      of: "^[A-Za-z0-9][A-Za-z0-9._:-]*$",
                      options: .regularExpression
                  ) != nil
            else {
                throw LatchwayError.invalidRequest(
                    "X-Latchway-Request-ID must match the client contract"
                )
            }
        }
        let forbiddenHeaders = [
            "X-Api-Key", "Api-Key", "X-Goog-Api-Key", "Proxy-Authorization",
            "X-Amz-Security-Token",
        ]
        guard forbiddenHeaders.allSatisfy({ request.value(forHTTPHeaderField: $0) == nil }) else {
            throw LatchwayError.invalidRequest(
                "Upstream provider credentials must not be supplied to Latchway"
            )
        }
        let forbiddenQueryNames: Set<String> = [
            "access_token", "api_key", "apikey", "auth_token", "key", "token",
            "x-amz-credential", "x-amz-signature", "x-goog-signature",
        ]
        let queryItems = request.url
            .flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }
            ?? []
        guard queryItems.allSatisfy({ !forbiddenQueryNames.contains($0.name.lowercased()) }) else {
            throw LatchwayError.invalidRequest(
                "Upstream provider credentials must not be supplied in the request URL"
            )
        }
    }

    private static func effectivePort(_ components: URLComponents) -> Int? {
        if let port = components.port { return port }
        switch components.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    private static func mediaType(_ value: String?) -> String? {
        value?
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func isWithinGatewayPath(_ requestPath: String, basePath: String) -> Bool {
        let normalizedBase = basePath.isEmpty || basePath == "/" ? "" : basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalizedBase.isEmpty else { return true }
        let prefix = "/" + normalizedBase
        return requestPath == prefix || requestPath.hasPrefix(prefix + "/")
    }

    private static func normalizedPath(_ url: URL) throws -> String {
        let htu = try LatchwayDPoPProofFactory.normalizedHTU(url)
        guard let path = URLComponents(string: htu)?.percentEncodedPath, !path.isEmpty else {
            throw LatchwayError.invalidRequest("The request URL path cannot be normalized")
        }
        return path
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
            && remote.session.expiresAt > Date(timeIntervalSince1970: 0)
            && (1 ... 128).contains(remote.requestID.utf8.count)
            && (1 ... 128).contains(remote.serverVersion.utf8.count)
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
    var requiresIdentityReauthentication: Bool {
        guard case let .server(problem) = self else { return false }
        return problem.code == .identityReauthenticationRequired || problem.code == .identityTokenExpired
    }

    var requiresFreshSession: Bool {
        guard case let .server(problem) = self else { return false }
        return [.refreshTokenReused, .installationRevoked, .sessionRevoked, .attestationStale, .attestationStepUpRequired].contains(problem.code)
    }

    var isSafeRefreshRejection: Bool {
        guard case let .server(problem) = self else { return false }
        return problem.code == .sessionExpired
            && problem.status == 401
            && problem.retryable
    }

    var isRevocation: Bool {
        guard case let .server(problem) = self else { return false }
        return problem.code == .installationRevoked || problem.code == .sessionRevoked
    }

    var stableLocalCode: String {
        switch self {
        case .invalidConfiguration: "configuration_invalid"
        case .invalidRequest: "request_invalid"
        case .secureEnclaveUnavailable, .keyStorageFailure: "key_unavailable"
        case .attestationUnavailable: "attestation_unsupported"
        case .invalidAttestationBinding: "attestation_invalid"
        case .sessionUnavailable: "session_unavailable"
        case .transportFailure: "transport_failure"
        case .invalidServerResponse: "server_response_invalid"
        case let .server(problem): problem.code.description
        case .cancelled: "cancelled"
        }
    }
}
