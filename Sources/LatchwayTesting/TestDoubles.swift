import CryptoKit
import Foundation
import Latchway

public struct LatchwayStaticIdentityTokenProvider: LatchwayIdentityTokenProvider {
    private let token: String

    public init(token: String) { self.token = token }
    public func identityToken() async throws -> String { token }
}

public struct LatchwayClosureIdentityTokenProvider: LatchwayIdentityTokenProvider {
    private let operation: @Sendable () async throws -> String

    public init(_ operation: @escaping @Sendable () async throws -> String) { self.operation = operation }
    public func identityToken() async throws -> String { try await operation() }
}

public actor LatchwayTestClock: LatchwayClock {
    private var instant: Date

    public init(now: Date) { instant = now }
    public func now() async -> Date { instant }
    public func advance(by interval: TimeInterval) { instant.addTimeInterval(interval) }
    public func set(_ date: Date) { instant = date }
}

public actor LatchwayInMemorySessionStorage: LatchwaySessionStorage {
    private var session: LatchwayStoredSession?
    private let failingSaveCalls: Set<Int>
    public private(set) var saveCount = 0
    public private(set) var clearCount = 0

    public init(
        session: LatchwayStoredSession? = nil,
        failingSaveCalls: Set<Int> = []
    ) {
        self.session = session
        self.failingSaveCalls = failingSaveCalls
    }
    public func load() async throws -> LatchwayStoredSession? { session }
    public func save(_ session: LatchwayStoredSession) async throws {
        saveCount += 1
        guard !failingSaveCalls.contains(saveCount) else {
            throw LatchwayError.keyStorageFailure
        }
        self.session = session
    }
    public func clear() async throws {
        session = nil
        clearCount += 1
    }
}

public actor LatchwayDeterministicInstallationKey: LatchwayInstallationKey {
    private var privateKey: P256.Signing.PrivateKey
    private let originalRepresentation: Data
    public private(set) var signatureCount = 0

    public init(rawPrivateKey: Data) throws {
        privateKey = try P256.Signing.PrivateKey(rawRepresentation: rawPrivateKey)
        originalRepresentation = rawPrivateKey
    }

    public func publicJWK() async throws -> LatchwayPublicJWK {
        let raw = privateKey.publicKey.x963Representation
        let x = Self.base64URL(raw[1 ..< 33])
        let y = Self.base64URL(raw[33 ..< 65])
        return LatchwayPublicJWK(x: x, y: y)
    }

    public func sign(_ message: Data) async throws -> Data {
        signatureCount += 1
        return try privateKey.signature(for: SHA256.hash(data: message)).rawRepresentation
    }

    public func storage() async -> LatchwayKeyStorage { .testing }

    public func reset() async throws {
        privateKey = try P256.Signing.PrivateKey(rawRepresentation: originalRepresentation)
        signatureCount = 0
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public actor LatchwayScriptedAttestationProvider: LatchwayAttestationProvider {
    private var results: [Result<LatchwayAttestationEvidence, Error>]
    private let reportedStatus: LatchwayAttestationStatus
    public private(set) var challenges: [LatchwayAttestationChallenge] = []
    public private(set) var acceptedEvidence: [LatchwayAttestationEvidence] = []
    public private(set) var resetCount = 0

    public init(
        results: [Result<LatchwayAttestationEvidence, Error>],
        status: LatchwayAttestationStatus = .init(support: .supported, keyID: "test-app-attest-key")
    ) {
        self.results = results
        reportedStatus = status
    }

    public func evidence(for challenge: LatchwayAttestationChallenge) async throws -> LatchwayAttestationEvidence {
        challenges.append(challenge)
        guard !results.isEmpty else { throw LatchwayError.attestationUnavailable }
        return try results.removeFirst().get()
    }

    public func didAccept(_ evidence: LatchwayAttestationEvidence) async {
        acceptedEvidence.append(evidence)
    }

    public func reset() async throws { resetCount += 1 }
    public func status() async -> LatchwayAttestationStatus { reportedStatus }
}

public actor LatchwayScriptedTransport: LatchwayHTTPTransport {
    public typealias Handler = @Sendable (URLRequest, Int) async throws -> LatchwayHTTPResponse

    private let handler: Handler
    public private(set) var requests: [URLRequest] = []

    public init(handler: @escaping Handler) { self.handler = handler }

    public func send(_ request: URLRequest) async throws -> LatchwayHTTPResponse {
        let index = requests.count
        requests.append(request)
        return try await handler(request, index)
    }
}

public struct LatchwayFixedAttestationProvider: LatchwayAttestationProvider {
    private let value: LatchwayAttestationEvidence
    private let reportedStatus: LatchwayAttestationStatus

    public init(
        evidence: LatchwayAttestationEvidence,
        status: LatchwayAttestationStatus = .init(support: .supported, keyID: "fixture-key")
    ) {
        value = evidence
        reportedStatus = status
    }

    public func evidence(for _: LatchwayAttestationChallenge) async throws -> LatchwayAttestationEvidence { value }
    public func reset() async throws {}
    public func status() async -> LatchwayAttestationStatus { reportedStatus }
}
