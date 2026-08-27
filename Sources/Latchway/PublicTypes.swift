import Foundation

public protocol LatchwayIdentityTokenProvider: Sendable {
    func identityToken() async throws -> String
}

public enum LatchwaySoftwareKeyFallbackPolicy: String, Sendable, Codable, CaseIterable {
    case disallow
    case allowWhenSecureEnclaveUnavailable
}

/// Identifies the client runtime using this native SDK.
///
/// The value is deliberately paired: it controls both the installation
/// platform sent during session establishment and the SDK identifier header.
/// This prevents a bridge from creating a session under one runtime while
/// identifying data-plane requests as another.
public enum LatchwayClientRuntime: String, Sendable, Codable, CaseIterable {
    case iOS = "ios"
    case reactNativeIOS = "react_native_ios"

    public var platformIdentifier: String { rawValue }

    public var sdkIdentifier: String {
        switch self {
        case .iOS: "ios"
        case .reactNativeIOS: "react-native"
        }
    }
}

public struct LatchwayConfiguration: Sendable {
    public let baseURL: URL
    public let applicationID: String
    public let environment: String
    public let identityProvider: String
    public let clientRuntime: LatchwayClientRuntime
    public let clientSDKVersion: String
    public let appVersion: String
    public let softwareKeyFallbackPolicy: LatchwaySoftwareKeyFallbackPolicy
    public let attestationProvider: (any LatchwayAttestationProvider)?
    public let controlRequestTimeout: TimeInterval

    public init(
        baseURL: URL,
        applicationID: String,
        environment: String,
        identityProvider: String = "firebase",
        clientRuntime: LatchwayClientRuntime = .iOS,
        clientSDKVersion: String = LatchwayVersion.sdk,
        appVersion: String? = nil,
        softwareKeyFallbackPolicy: LatchwaySoftwareKeyFallbackPolicy = .disallow,
        attestationProvider: (any LatchwayAttestationProvider)? = nil,
        controlRequestTimeout: TimeInterval = 30
    ) {
        self.baseURL = baseURL
        self.applicationID = applicationID
        self.environment = environment
        self.identityProvider = identityProvider
        self.clientRuntime = clientRuntime
        self.clientSDKVersion = clientSDKVersion
        self.appVersion = appVersion ?? Self.defaultAppVersion
        self.softwareKeyFallbackPolicy = softwareKeyFallbackPolicy
        self.attestationProvider = attestationProvider
        self.controlRequestTimeout = controlRequestTimeout
    }

    private static var defaultAppVersion: String {
        if let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String, !version.isEmpty {
            return version
        }
        return "0.0.0"
    }
}

public enum LatchwayJSONValue: Sendable, Codable, Equatable {
    case null
    case bool(Bool)
    case number(Decimal)
    case string(String)
    case array([LatchwayJSONValue])
    case object([String: LatchwayJSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Decimal.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([LatchwayJSONValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: LatchwayJSONValue].self) { self = .object(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}

public struct LatchwayPublicJWK: Sendable, Codable, Equatable {
    public let keyType: String
    public let curve: String
    public let x: String
    public let y: String

    enum CodingKeys: String, CodingKey {
        case keyType = "kty"
        case curve = "crv"
        case x, y
    }

    public init(x: String, y: String) {
        self.keyType = "EC"
        self.curve = "P-256"
        self.x = x
        self.y = y
    }
}

public enum LatchwayKeyStorage: String, Sendable, Codable, CaseIterable {
    case secureEnclave = "secure_enclave"
    case keychainSoftware = "keychain_software"
    case testing
    case unavailable
}

public struct LatchwayAttestationChallenge: Sendable, Equatable {
    public let id: String
    public let provider: String
    public let clientDataHash: Data
    public let expiresAt: Date
    public let options: [String: LatchwayJSONValue]

    public init(
        id: String,
        provider: String,
        clientDataHash: Data,
        expiresAt: Date,
        options: [String: LatchwayJSONValue] = [:]
    ) {
        self.id = id
        self.provider = provider
        self.clientDataHash = clientDataHash
        self.expiresAt = expiresAt
        self.options = options
    }
}

public struct LatchwayAttestationEvidence: Sendable, Codable, Equatable {
    public let provider: String
    public let evidence: [String: LatchwayJSONValue]

    public init(provider: String, evidence: [String: LatchwayJSONValue]) {
        self.provider = provider
        self.evidence = evidence
    }
}

public struct LatchwayAttestationStatus: Sendable, Equatable {
    public enum Support: String, Sendable, Codable {
        case supported, unsupported, unknown
    }

    public let support: Support
    public let keyID: String?
    public let lastOperation: String?

    public init(support: Support, keyID: String? = nil, lastOperation: String? = nil) {
        self.support = support
        self.keyID = keyID
        self.lastOperation = lastOperation
    }
}

public struct LatchwayQuotaSnapshot: Sendable, Codable, Equatable {
    public struct Limit: Sendable, Codable, Equatable {
        public let metric: String
        public let maximum: Int64?
        public let used: Int64?
        public let reserved: Int64?
        public let remaining: Int64?
        public let resetsAt: Date?
        public let hard: Bool

        enum CodingKeys: String, CodingKey {
            case metric, maximum, used, reserved, remaining, hard
            case resetsAt = "resets_at"
        }
    }

    public let feature: String
    public let observedAt: Date
    public let limits: [Limit]

    enum CodingKeys: String, CodingKey {
        case feature, limits
        case observedAt = "observed_at"
    }
}

public struct LatchwayInstallationSummary: Sendable, Codable, Equatable {
    public let id: String
    public let platform: String
    public let dpopJKT: String
    public let status: String

    enum CodingKeys: String, CodingKey {
        case id, platform, status
        case dpopJKT = "dpop_jkt"
    }
}

public struct LatchwayTrustSummary: Sendable, Codable, Equatable {
    public let provider: String
    public let level: String
    public let verifiedAt: Date
    public let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case provider, level
        case verifiedAt = "verified_at"
        case expiresAt = "expires_at"
    }
}

public struct LatchwayDiagnostics: Sendable, Equatable {
    public enum SessionState: String, Sendable, Codable {
        case absent, establishing, active, refreshing, expired, revoked, failed
    }

    public let sdkVersion: String
    public let contractVersion: String
    public let protocolVersion: Int
    public let keyStorage: LatchwayKeyStorage
    public let keyThumbprint: String?
    public let attestation: LatchwayAttestationStatus
    public let sessionState: SessionState
    public let sessionExpiresAt: Date?
    public let installationID: String?
    public let serverVersion: String?
    public let lastRequestID: String?
    public let lastErrorCode: String?

    public init(
        sdkVersion: String = LatchwayVersion.sdk,
        contractVersion: String = LatchwayVersion.contract,
        protocolVersion: Int = LatchwayVersion.protocolVersion,
        keyStorage: LatchwayKeyStorage,
        keyThumbprint: String? = nil,
        attestation: LatchwayAttestationStatus,
        sessionState: SessionState,
        sessionExpiresAt: Date? = nil,
        installationID: String? = nil,
        serverVersion: String? = nil,
        lastRequestID: String? = nil,
        lastErrorCode: String? = nil
    ) {
        self.sdkVersion = sdkVersion
        self.contractVersion = contractVersion
        self.protocolVersion = protocolVersion
        self.keyStorage = keyStorage
        self.keyThumbprint = keyThumbprint
        self.attestation = attestation
        self.sessionState = sessionState
        self.sessionExpiresAt = sessionExpiresAt
        self.installationID = installationID
        self.serverVersion = serverVersion
        self.lastRequestID = lastRequestID
        self.lastErrorCode = lastErrorCode
    }
}
