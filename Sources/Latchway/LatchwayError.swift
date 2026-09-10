import Foundation

public enum LatchwayErrorCode: Sendable, Equatable, Hashable, CustomStringConvertible {
    case requestInvalid
    case identityTokenMissing
    case identityTokenInvalid
    case identityTokenExpired
    case identityReauthenticationRequired
    case attestationRequired
    case attestationUnsupported
    case attestationInvalid
    case attestationStale
    case attestationStepUpRequired
    case dpopMissing
    case dpopInvalid
    case dpopReplayed
    case dpopNonceRequired
    case sessionExpired
    case sessionRevoked
    case refreshTokenReused
    case installationRevoked
    case installationFamilyRevoked
    case installationFamilyNotFound
    case componentDefinitionNotFound
    case componentNotConfigured
    case componentNotProvisioned
    case componentRevoked
    case componentKeyInvalid
    case componentKeyReplaced
    case componentDelegationExpired
    case componentFeatureNotGranted
    case componentParentTrustExpired
    case componentDirectAttestationRequired
    case containingAppSetupRequired
    case frameworkIntegrationUnsupported
    case frameworkVersionUnsupported
    case transportDestinationNotAllowed
    case transportRequestNotReplayable
    case featureNotFound
    case featureNotAllowed
    case modelNotAllowed
    case quotaExceeded
    case concurrencyExceeded
    case outputLimitExceeded
    case pricingUnavailable
    case routeNotFound
    case upstreamUnavailable
    case upstreamTimeout
    case upstreamProtocolError
    case configurationInvalid
    case serverNotReady
    case protocolVersionUnsupported
    case rateLimited
    case operationIndeterminate
    case internalError
    case unknown(String)

    public init(rawValue: String) {
        self = Self.known[rawValue] ?? .unknown(rawValue)
    }

    public var description: String {
        switch self {
        case let .unknown(value): value
        default: Self.rawByKnown[self]!
        }
    }

    /// Stable public documentation for this wire error code.
    ///
    /// Unknown future codes remain linkable without allowing their value to
    /// escape the final URL path segment.
    public var documentationURL: URL {
        let segment = description.replacingOccurrences(of: "_", with: "-").addingPercentEncoding(
            withAllowedCharacters: Self.documentationPathSegmentCharacters
        )!
        return URL(string: "https://docs.latchway.dev/errors/\(segment)")!
    }

    private static let known: [String: Self] = [
        "request_invalid": .requestInvalid,
        "identity_token_missing": .identityTokenMissing,
        "identity_token_invalid": .identityTokenInvalid,
        "identity_token_expired": .identityTokenExpired,
        "identity_reauthentication_required": .identityReauthenticationRequired,
        "attestation_required": .attestationRequired,
        "attestation_unsupported": .attestationUnsupported,
        "attestation_invalid": .attestationInvalid,
        "attestation_stale": .attestationStale,
        "attestation_step_up_required": .attestationStepUpRequired,
        "dpop_missing": .dpopMissing,
        "dpop_invalid": .dpopInvalid,
        "dpop_replayed": .dpopReplayed,
        "dpop_nonce_required": .dpopNonceRequired,
        "session_expired": .sessionExpired,
        "session_revoked": .sessionRevoked,
        "refresh_token_reused": .refreshTokenReused,
        "installation_revoked": .installationRevoked,
        "installation_family_revoked": .installationFamilyRevoked,
        "installation_family_not_found": .installationFamilyNotFound,
        "component_definition_not_found": .componentDefinitionNotFound,
        "component_not_configured": .componentNotConfigured,
        "component_not_provisioned": .componentNotProvisioned,
        "component_revoked": .componentRevoked,
        "component_key_invalid": .componentKeyInvalid,
        "component_key_replaced": .componentKeyReplaced,
        "component_delegation_expired": .componentDelegationExpired,
        "component_feature_not_granted": .componentFeatureNotGranted,
        "component_parent_trust_expired": .componentParentTrustExpired,
        "component_direct_attestation_required": .componentDirectAttestationRequired,
        "containing_app_setup_required": .containingAppSetupRequired,
        "framework_integration_unsupported": .frameworkIntegrationUnsupported,
        "framework_version_unsupported": .frameworkVersionUnsupported,
        "transport_destination_not_allowed": .transportDestinationNotAllowed,
        "transport_request_not_replayable": .transportRequestNotReplayable,
        "feature_not_found": .featureNotFound,
        "feature_not_allowed": .featureNotAllowed,
        "model_not_allowed": .modelNotAllowed,
        "quota_exceeded": .quotaExceeded,
        "concurrency_exceeded": .concurrencyExceeded,
        "output_limit_exceeded": .outputLimitExceeded,
        "pricing_unavailable": .pricingUnavailable,
        "route_not_found": .routeNotFound,
        "upstream_unavailable": .upstreamUnavailable,
        "upstream_timeout": .upstreamTimeout,
        "upstream_protocol_error": .upstreamProtocolError,
        "configuration_invalid": .configurationInvalid,
        "server_not_ready": .serverNotReady,
        "protocol_version_unsupported": .protocolVersionUnsupported,
        "rate_limited": .rateLimited,
        "operation_indeterminate": .operationIndeterminate,
        "internal_error": .internalError,
    ]

    private static let rawByKnown: [Self: String] = Dictionary(uniqueKeysWithValues: known.map { ($0.value, $0.key) })

    private static let documentationPathSegmentCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
    )
}

public struct LatchwayProblem: Sendable, Equatable, Error {
    public struct FieldError: Sendable, Equatable, Decodable {
        public let path: String
        public let message: String

        public init(path: String, message: String) {
            self.path = path
            self.message = message
        }
    }

    public let code: LatchwayErrorCode
    public let title: String
    public let detail: String
    public let status: Int
    public let requestID: String
    public let retryable: Bool
    public let retryAfter: Date?
    /// The canonical audit correlation identifier required for an
    /// indeterminate operation outcome.
    public let operationID: String?
    public let feature: String?
    public let errors: [FieldError]?
    public let supportedProtocolVersions: [Int]?
    /// An opaque diagnostic reference. The SDK never follows this URI.
    public let instance: String?

    public init(
        code: LatchwayErrorCode,
        title: String,
        detail: String,
        status: Int,
        requestID: String,
        retryable: Bool,
        retryAfter: Date? = nil,
        operationID: String? = nil,
        feature: String? = nil,
        errors: [FieldError]? = nil,
        supportedProtocolVersions: [Int]? = nil,
        instance: String? = nil
    ) {
        self.code = code
        self.title = title
        self.detail = detail
        self.status = status
        self.requestID = requestID
        self.retryable = retryable
        self.retryAfter = retryAfter
        self.operationID = operationID
        self.feature = feature
        self.errors = errors
        self.supportedProtocolVersions = supportedProtocolVersions
        self.instance = instance
    }

    /// Stable remediation documentation for ``code``.
    public var documentationURL: URL { code.documentationURL }

    /// Decode a bounded, canonical gateway Problem response for a custom transport.
    /// Unknown optional members are ignored, not copied into diagnostics. Invalid
    /// bodies never become displayable provider text or retry instructions.
    public static func decode(from data: Data, response: HTTPURLResponse) throws -> Self {
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            guard let name = entry.key as? String, let value = entry.value as? String else { return }
            result[name] = value
        }
        return try decode(from: LatchwayHTTPResponse(statusCode: response.statusCode, headers: headers, body: data))
    }

    public static func decode(from response: LatchwayHTTPResponse) throws -> Self {
        do {
            guard (400 ... 599).contains(response.statusCode), response.body.count <= 65_536,
                  response.header("Content-Type")?.split(separator: ";", maxSplits: 1).first?
                    .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "application/problem+json"
            else { throw LatchwayError.invalidServerResponse }
            try StrictJSON.validate(response.body)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .latchwayISO8601
            let wire = try decoder.decode(ProblemWire.self, from: response.body)
            guard wire.isValid, wire.status == response.statusCode,
                  response.header("X-Latchway-Request-ID") == nil
                    || response.header("X-Latchway-Request-ID") == wire.requestID
            else { throw LatchwayError.invalidServerResponse }
            return wire.problem
        } catch {
            throw LatchwayHTTPResponseError(
                statusCode: response.statusCode,
                requestID: safeRequestID(response.header("X-Latchway-Request-ID"))
            )
        }
    }

    static func safeRequestID(_ value: String?) -> String? {
        guard let value, value.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$", options: .regularExpression) != nil else { return nil }
        return value
    }
}

public enum LatchwayError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    case invalidConfiguration(String)
    case invalidRequest(String)
    case secureEnclaveUnavailable
    case keyStorageFailure
    case attestationUnavailable
    case invalidAttestationBinding
    case sessionUnavailable
    case transportFailure
    case invalidServerResponse
    case server(LatchwayProblem)
    case cancelled

    public var description: String {
        switch self {
        case let .invalidConfiguration(reason): "Latchway configuration is invalid: \(reason)"
        case let .invalidRequest(reason): "Latchway request is invalid: \(reason)"
        case .secureEnclaveUnavailable: "Secure Enclave is unavailable and software fallback is disabled."
        case .keyStorageFailure: "The installation key or session could not be stored securely."
        case .attestationUnavailable: "The required platform attestation provider is unavailable."
        case .invalidAttestationBinding: "The server supplied an invalid attestation binding."
        case .sessionUnavailable: "A Latchway session could not be established."
        case .transportFailure: "A Latchway transport operation failed."
        case .invalidServerResponse: "Latchway returned an invalid response."
        case let .server(problem): "Latchway request failed (\(problem.code), request \(problem.requestID))."
        case .cancelled: "The Latchway operation was cancelled."
        }
    }

    public var errorDescription: String? { description }

    /// Stable redaction-safe code for local and server failures.
    public var code: String {
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

    /// Stable public remediation documentation for ``code``.
    public var documentationURL: URL {
        let segment = code.replacingOccurrences(of: "_", with: "-").addingPercentEncoding(
            withAllowedCharacters: CharacterSet(
                charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
            )
        )!
        return URL(string: "https://docs.latchway.dev/errors/\(segment)")!
    }
}

/// Safe HTTP diagnostics for a malformed gateway error body. Kept separate from
/// `LatchwayError` so existing exhaustive switches remain source-compatible.
public struct LatchwayHTTPResponseError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    public let statusCode: Int
    public let requestID: String?

    public init(statusCode: Int, requestID: String?) {
        self.statusCode = statusCode
        self.requestID = LatchwayProblem.safeRequestID(requestID)
    }

    public var code: String { "server_response_invalid" }
    public var documentationURL: URL { LatchwayError.invalidServerResponse.documentationURL }
    public var description: String {
        "Latchway returned an invalid HTTP \(statusCode) response\(requestID.map { " (request \($0))" } ?? "")."
    }
    public var errorDescription: String? { description }
}
