import Foundation

struct SessionChallengeRequest: Encodable {
    let applicationID: String
    let environment: String
    let identityProvider: String
    let identityToken: String
    let platform: String
    let sdkVersion: String

    enum CodingKeys: String, CodingKey {
        case environment, platform
        case applicationID = "application_id"
        case identityProvider = "identity_provider"
        case identityToken = "identity_token"
        case sdkVersion = "sdk_version"
    }
}

struct SessionChallengeWire: Decodable, Sendable {
    struct Attestation: Decodable, Sendable {
        let provider: String
        let mode: String
        let clientDataHash: String
        let providerOptions: [String: LatchwayJSONValue]?

        enum CodingKeys: String, CodingKey {
            case provider, mode
            case clientDataHash = "client_data_hash"
            case providerOptions = "provider_options"
        }
    }

    let challengeID: String
    let challengeNonce: String
    let bindingVersion: Int
    let issuedAt: Int64
    let expiresAt: Date
    let attestation: Attestation

    enum CodingKeys: String, CodingKey {
        case attestation
        case challengeID = "challenge_id"
        case challengeNonce = "challenge_nonce"
        case bindingVersion = "binding_version"
        case issuedAt = "issued_at"
        case expiresAt = "expires_at"
    }
}

struct SessionExchangeRequest: Encodable {
    struct Installation: Encodable {
        let appVersion: String
        let osVersion: String
        let deviceModel: String

        enum CodingKeys: String, CodingKey {
            case appVersion = "app_version"
            case osVersion = "os_version"
            case deviceModel = "device_model"
        }
    }

    let challengeID: String
    let attestation: LatchwayAttestationEvidence
    let installation: Installation

    enum CodingKeys: String, CodingKey {
        case attestation, installation
        case challengeID = "challenge_id"
    }
}

struct SessionRefreshRequest: Encodable {
    let refreshToken: String
    let identityToken: String?
    let attestation: LatchwayAttestationEvidence?

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
        case identityToken = "identity_token"
        case attestation
    }
}

struct SessionGrantWire: Decodable, Sendable {
    let accessToken: String
    let tokenType: String
    let expiresIn: Int
    let refreshToken: String
    let refreshExpiresIn: Int
    let installation: LatchwayInstallationSummary
    let trust: LatchwayTrustSummary

    enum CodingKeys: String, CodingKey {
        case installation, trust
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case refreshExpiresIn = "refresh_expires_in"
    }
}

struct ClientDiagnosticsWire: Decodable, Sendable {
    struct Session: Decodable, Sendable {
        let expiresAt: Date
        let refreshAvailable: Bool

        enum CodingKeys: String, CodingKey {
            case expiresAt = "expires_at"
            case refreshAvailable = "refresh_available"
        }
    }

    let requestID: String
    let serverVersion: String
    let contractVersion: String
    let protocolVersion: Int
    let installation: LatchwayInstallationSummary
    let session: Session
    let trust: LatchwayTrustSummary

    enum CodingKeys: String, CodingKey {
        case installation, session, trust
        case requestID = "request_id"
        case serverVersion = "server_version"
        case contractVersion = "contract_version"
        case protocolVersion = "protocol_version"
    }
}

struct ProblemWire: Decodable {
    let type: String
    let title: String
    let status: Int
    let detail: String
    let code: String
    let requestID: String
    let retryable: Bool
    let retryAfter: Date?
    let operationID: String?
    private let operationIDMemberPresent: Bool

    enum CodingKeys: String, CodingKey {
        case type, title, status, detail, code, retryable
        case requestID = "request_id"
        case retryAfter = "retry_after"
        case operationID = "operation_id"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        title = try container.decode(String.self, forKey: .title)
        status = try container.decode(Int.self, forKey: .status)
        detail = try container.decode(String.self, forKey: .detail)
        code = try container.decode(String.self, forKey: .code)
        requestID = try container.decode(String.self, forKey: .requestID)
        retryable = try container.decode(Bool.self, forKey: .retryable)
        retryAfter = try container.decodeIfPresent(Date.self, forKey: .retryAfter)
        operationID = try container.decodeIfPresent(String.self, forKey: .operationID)
        operationIDMemberPresent = container.contains(.operationID)
    }

    var problem: LatchwayProblem {
        LatchwayProblem(
            code: LatchwayErrorCode(rawValue: code),
            title: title,
            detail: detail,
            status: status,
            requestID: requestID,
            retryable: retryable,
            retryAfter: retryAfter,
            operationID: operationID
        )
    }

    var isValid: Bool {
        guard let typeURL = URL(string: type), typeURL.scheme != nil else { return false }
        return (1 ... 256).contains(title.utf8.count)
            && (400 ... 599).contains(status)
            && (1 ... 2_048).contains(detail.utf8.count)
            && (8 ... 128).contains(requestID.utf8.count)
            && code.range(of: "^[a-z][a-z0-9_]{0,62}$", options: .regularExpression) != nil
            && Self.hasValidOperationContract(
                code: LatchwayErrorCode(rawValue: code),
                status: status,
                retryable: retryable,
                operationID: operationID,
                operationIDMemberPresent: operationIDMemberPresent
            )
    }

    static func hasValidOperationContract(
        code: LatchwayErrorCode,
        status: Int,
        retryable: Bool,
        operationID: String?,
        operationIDMemberPresent: Bool
    ) -> Bool {
        if code == .operationIndeterminate {
            return status == 503
                && retryable
                && operationID.map(isCanonicalOperationID) == true
        }
        return !operationIDMemberPresent
    }

    private static func isCanonicalOperationID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 30,
              bytes.starts(with: Array("arq_".utf8)),
              (0x30 ... 0x37).contains(bytes[4])
        else { return false }
        let alphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8)
        return bytes.dropFirst(5).allSatisfy(alphabet.contains)
    }
}

struct RuntimeSession: Sendable, Equatable {
    let accessToken: String
    let expiresAt: Date
    let refreshToken: String
    let refreshExpiresAt: Date
    let installation: LatchwayInstallationSummary
    let trust: LatchwayTrustSummary

    func isUsable(at now: Date, leeway: TimeInterval = 30) -> Bool {
        expiresAt.timeIntervalSince(now) > leeway
    }
}
