import Foundation

public protocol LatchwayAttestationProvider: Sendable {
    func evidence(for challenge: LatchwayAttestationChallenge) async throws -> LatchwayAttestationEvidence
    func didAccept(_ evidence: LatchwayAttestationEvidence) async
    func reset() async throws
    func status() async -> LatchwayAttestationStatus
}

public extension LatchwayAttestationProvider {
    func didAccept(_: LatchwayAttestationEvidence) async {}
}

public protocol LatchwayInstallationKey: Sendable {
    func publicJWK() async throws -> LatchwayPublicJWK
    func sign(_ message: Data) async throws -> Data
    func storage() async -> LatchwayKeyStorage
    func reset() async throws
}

public struct LatchwayHTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public protocol LatchwayHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> LatchwayHTTPResponse
}

public struct LatchwayStoredSession: Sendable, Codable, Equatable {
    public let refreshToken: String
    public let refreshExpiresAt: Date
    public let installation: LatchwayInstallationSummary
    public let installationFamily: LatchwayInstallationFamilySummary?
    public let component: LatchwayClientComponentSummary?

    public init(
        refreshToken: String,
        refreshExpiresAt: Date,
        installation: LatchwayInstallationSummary,
        installationFamily: LatchwayInstallationFamilySummary? = nil,
        component: LatchwayClientComponentSummary? = nil
    ) {
        self.refreshToken = refreshToken
        self.refreshExpiresAt = refreshExpiresAt
        self.installation = installation
        self.installationFamily = installationFamily
        self.component = component
    }
}

public protocol LatchwaySessionStorage: Sendable {
    func load() async throws -> LatchwayStoredSession?
    func save(_ session: LatchwayStoredSession) async throws
    func clear() async throws
}

public protocol LatchwayClock: Sendable {
    func now() async -> Date
}

public struct LatchwaySystemClock: LatchwayClock {
    public init() {}
    public func now() async -> Date { Date() }
}
