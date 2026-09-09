import Foundation

/// Public JWT metadata only. This type never imports an authentication SDK,
/// discovers an auth instance, fetches tokens, or authenticates a decoded JWT.
public struct LatchwaySuppliedIdentityConfiguration: Sendable, Equatable {
    public let providerID: String
    public let issuer: String
    public let audience: String
    public let tenantID: String?

    public init(providerID: String, issuer: String, audience: String, tenantID: String? = nil) {
        self.providerID = providerID
        self.issuer = issuer
        self.audience = audience
        self.tenantID = tenantID
    }

    public static func firebaseProject(projectID: String, tenantID: String? = nil,
                                       providerID: String = "firebase") throws -> Self {
        guard projectID.range(of: "^[a-z][a-z0-9-]{4,28}[a-z0-9]$", options: .regularExpression) != nil else {
            throw LatchwayLifecycleError.configurationConflict
        }
        let value = Self(providerID: providerID, issuer: "https://securetoken.google.com/\(projectID)",
                         audience: projectID, tenantID: tenantID)
        try value.validate()
        return value
    }

    func validate() throws {
        guard (1 ... 128).contains(providerID.utf8.count), (1 ... 2048).contains(issuer.utf8.count),
              (1 ... 2048).contains(audience.utf8.count),
              tenantID.map({ (1 ... 256).contains($0.utf8.count) }) ?? true,
              let url = URL(string: issuer), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw LatchwayLifecycleError.configurationConflict
        }
    }

    var reference: LatchwayIdentityAuthorityReference {
        .init(name: "supplied:\(providerID):\(audience)", issuer: issuer, tenant: tenantID)
    }
}

struct LatchwaySuppliedToken: Sendable {
    let snapshot: LatchwayIdentitySnapshot
    let expiresAt: Date

    init(_ token: String, configuration: LatchwaySuppliedIdentityConfiguration, now: Date = Date()) throws {
        guard (16 ... 65_536).contains(token.utf8.count) else { throw LatchwayLifecycleError.identityUnavailable }
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3, segments.allSatisfy({ !$0.isEmpty }),
              let data = try? Base64URL.decode(String(segments[1])), data.count <= 49_152,
              (try? StrictJSON.validate(data)) != nil,
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let issuer = claims["iss"] as? String, issuer == configuration.issuer,
              let subject = claims["sub"] as? String, (1 ... 1024).contains(subject.utf8.count),
              let expiry = claims["exp"] as? NSNumber, CFGetTypeID(expiry) != CFBooleanGetTypeID(),
              expiry.doubleValue.isFinite, expiry.doubleValue > now.timeIntervalSince1970 else {
            throw LatchwayLifecycleError.identityUnavailable
        }
        let audiences = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        let tenant = (claims["firebase"] as? [String: Any])?["tenant"] as? String ?? claims["tenant_id"] as? String
        guard audiences.contains(configuration.audience), tenant == configuration.tenantID else {
            throw LatchwayLifecycleError.identityUnavailable
        }
        snapshot = .init(issuer: issuer, tenant: tenant, subject: subject, token: token)
        expiresAt = Date(timeIntervalSince1970: expiry.doubleValue)
    }
}

/// Memory-only verified token store. Staged/unverified input is never visible
/// to ordinary clients, even if an older Latchway session is cached.
final class LatchwaySuppliedIdentityAuthority: LatchwayIdentityAuthority, @unchecked Sendable {
    // Every mutable field is protected by this one lock. App actor mutations
    // are synchronous: no stale cancellation may reopen a newer ticket during
    // an actor hop between reserving the ticket and suspending identity.
    private let lock = NSLock()
    let freshness = LatchwayIdentityFreshnessFence()
    private var token: LatchwaySuppliedToken?
    private var verifiedExpiresAt: Date?
    private var suspended = true
    private var operationID: UUID?

    func identitySnapshot() async throws -> LatchwayIdentitySnapshot? {
        try lock.withLock {
            try freshness.check()
            guard !suspended, let token, let verifiedExpiresAt, verifiedExpiresAt > Date() else {
                throw LatchwayLifecycleError.identityRefreshRequired
            }
            return token.snapshot
        }
    }
    func suspend(operationID: UUID) {
        lock.withLock { self.operationID = operationID; suspended = true; freshness.suspend() }
    }
    func clear() {
        lock.withLock { token = nil; verifiedExpiresAt = nil; operationID = nil; suspended = true; freshness.suspend() }
    }
    func commit(_ value: LatchwaySuppliedToken, expiresAt: Date, operationID: UUID) throws {
        try lock.withLock {
            guard self.operationID == operationID else { throw LatchwayLifecycleError.accountChanged }
            let deadline = min(value.expiresAt, expiresAt)
            guard deadline > Date() else { throw LatchwayLifecycleError.identityRefreshRequired }
            token = value
            verifiedExpiresAt = deadline
            suspended = false
            freshness.commit(deadline)
            self.operationID = nil
        }
    }
    func resume(operationID: UUID) {
        lock.withLock {
            guard self.operationID == operationID else { return }
            self.operationID = nil
            suspended = false
            if let verifiedExpiresAt { freshness.commit(verifiedExpiresAt) }
        }
    }
    func isFresh() -> Bool { lock.withLock { !suspended && (verifiedExpiresAt ?? .distantPast) > Date() } }
    func expiration() -> Date? { lock.withLock { verifiedExpiresAt } }
}

/// No credentials; lock-protected freshness is checked for every buffered or
/// streamed byte without an actor hop, including while a refresh is pending.
final class LatchwayIdentityFreshnessFence: @unchecked Sendable {
    private let lock = NSLock()
    private var deadline: Date?
    func suspend() { lock.withLock { deadline = nil } }
    func commit(_ date: Date) { lock.withLock { deadline = date } }
    func check() throws {
        try lock.withLock {
            guard let deadline, deadline > Date() else { throw LatchwayLifecycleError.identityRefreshRequired }
        }
    }
}

/// All mutable token state is protected by the same lock.
final class LatchwayOneShotTokenProvider: LatchwayIdentityTokenProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    init(token: String) { self.token = token }
    func identityToken() throws -> String {
        try lock.withLock {
            guard let token else { throw LatchwayLifecycleError.loggedOut }
            return token
        }
    }
    func clear() { lock.withLock { token = nil } }
}

/// An opaque lease on one accepted sign-in. Old handles cannot update or log
/// out a later user, including another sign-in of the same subject.
public struct LatchwayAccount: Sendable {
    private let app: LatchwayApp
    let generationID: UUID
    init(app: LatchwayApp, generationID: UUID) { self.app = app; self.generationID = generationID }
    public func makeClient(runtime: LatchwayClientRuntime = .iOS) async throws -> LatchwayClient {
        try await app.makeClient(runtime: runtime, generationID: generationID)
    }
    public func updateIdToken(_ idToken: String) async throws {
        try await updateIdToken { idToken }
    }
    public func updateIdToken(getIdToken: @escaping @Sendable () async throws -> String) async throws {
        _ = try await app.acquireIdentity(intent: .update, generationID: generationID, getIdToken: getIdToken)
    }
    public func logout() async throws { try await app.logout(generationID: generationID) }
}

/// Bridge-facing intent. Application code normally uses signIn/restore/account.updateIdToken.
public enum LatchwayIdentityIntent: String, Sendable { case signIn, restore, update }
