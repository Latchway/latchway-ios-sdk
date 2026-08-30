import Foundation

enum LatchwayComponentRequestSecurity {
    static func prepare(
        _ request: inout URLRequest,
        configuration: LatchwayConfiguration,
        framework: LatchwayFrameworkMetadata?,
        allowManagedPlaceholder: Bool
    ) throws {
        guard let url = request.url else {
            throw LatchwayError.invalidRequest("URLRequest must contain a URL")
        }
        try validateDestination(url, baseURL: configuration.baseURL)
        if allowManagedPlaceholder { stripManagedPlaceholder(from: &request) }
        try rejectCredentials(in: request)
        try validateFrameworkHeaders(in: request, framework: framework)
        try validateFramework(framework)
    }

    static func addMetadata(
        to request: inout URLRequest,
        configuration: LatchwayConfiguration,
        framework: LatchwayFrameworkMetadata?
    ) {
        request.setValue(configuration.clientRuntime.sdkIdentifier, forHTTPHeaderField: "X-Latchway-SDK")
        request.setValue(configuration.clientSDKVersion, forHTTPHeaderField: "X-Latchway-SDK-Version")
        request.setValue(String(LatchwayVersion.protocolVersion), forHTTPHeaderField: "X-Latchway-Protocol-Version")
        if let framework {
            request.setValue(framework.identifier, forHTTPHeaderField: "X-Latchway-Framework")
            request.setValue(framework.version, forHTTPHeaderField: "X-Latchway-Framework-Version")
        }
        if request.value(forHTTPHeaderField: "X-Latchway-Request-ID") == nil {
            request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Latchway-Request-ID")
        }
    }

    private static func validateDestination(_ url: URL, baseURL: URL) throws {
        guard let request = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let gateway = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let gatewayScheme = gateway.scheme?.lowercased(),
              let gatewayHost = gateway.host?.lowercased(),
              !gatewayHost.isEmpty,
              gateway.user == nil,
              gateway.password == nil,
              gateway.query == nil,
              gateway.fragment == nil,
              gatewayScheme == "https" || (gatewayScheme == "http" && isLoopback(gatewayHost)),
              request.scheme?.lowercased() == gatewayScheme,
              request.host?.lowercased() == gatewayHost,
              effectivePort(request) == effectivePort(gateway),
              request.user == nil,
              request.password == nil,
              request.fragment == nil
        else {
            throw LatchwayError.invalidRequest(
                "Requests may only be authorized for the configured Latchway origin"
            )
        }
        let requestPath = try normalizedPath(url)
        let basePath = try normalizedPath(baseURL)
        let base = basePath == "/"
            ? ""
            : basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let prefix = base.isEmpty ? "" : "/\(base)"
        guard requestPath == prefix || requestPath.hasPrefix(prefix + "/") else {
            throw LatchwayError.invalidRequest("The request escaped the configured Latchway path")
        }
        let relative = String(requestPath.dropFirst(prefix.count))
        guard relative == "/v1" || relative.hasPrefix("/v1/") else {
            throw LatchwayError.invalidRequest("The request path is not a Latchway data-plane path")
        }
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private static func stripManagedPlaceholder(from request: inout URLRequest) {
        for header in ["Authorization", "api-key", "x-api-key"] {
            guard let value = request.value(forHTTPHeaderField: header) else { continue }
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let accepted = normalized.caseInsensitiveCompare(
                "Bearer \(LatchwayFeatureTransport.placeholderAPIKey)"
            ) == .orderedSame || normalized == LatchwayFeatureTransport.placeholderAPIKey
            if accepted { request.setValue(nil, forHTTPHeaderField: header) }
        }
    }

    private static func rejectCredentials(in request: URLRequest) throws {
        if let requestID = request.value(forHTTPHeaderField: "X-Latchway-Request-ID") {
            guard (8 ... 128).contains(requestID.utf8.count),
                  requestID.range(
                      of: "^[A-Za-z0-9][A-Za-z0-9._:-]*$",
                      options: .regularExpression
                  ) != nil
            else { throw LatchwayError.invalidRequest("X-Latchway-Request-ID is invalid") }
        }
        let headerNames = Set((request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
        guard headerNames.isDisjoint(with: forbiddenCredentialNames) else {
            throw LatchwayError.invalidRequest("Upstream provider credentials must not be supplied")
        }
        let queryItems = request.url
            .flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }
            ?? []
        guard queryItems.allSatisfy({ !forbiddenCredentialNames.contains(decodedName($0.name)) }) else {
            throw LatchwayError.invalidRequest("Upstream provider credentials must not be supplied")
        }
    }

    private static func validateFramework(_ framework: LatchwayFrameworkMetadata?) throws {
        guard let framework else { return }
        try framework.validate()
    }

    private static func validateFrameworkHeaders(
        in request: URLRequest,
        framework: LatchwayFrameworkMetadata?
    ) throws {
        let suppliedID = request.value(forHTTPHeaderField: "X-Latchway-Framework")
        let suppliedVersion = request.value(forHTTPHeaderField: "X-Latchway-Framework-Version")
        guard suppliedID == nil, suppliedVersion == nil else {
            guard let framework,
                  suppliedID == framework.identifier,
                  suppliedVersion == framework.version
            else {
                throw LatchwayError.invalidRequest(
                    "Framework metadata must be supplied through the native Latchway transport"
                )
            }
            return
        }
    }

    private static let forbiddenCredentialNames: Set<String> = [
        "authorization", "proxy-authorization", "api-key", "api_key", "apikey", "x-api-key",
        "openai-api-key", "openai_api_key", "x-openai-api-key", "anthropic-api-key",
        "anthropic_api_key", "access_token", "auth_token", "token", "key", "x-auth-token",
        "cookie", "x-amz-credential", "x-amz-security-token", "x-amz-signature", "x-goog-api-key",
        "x-goog_api_key", "x-goog-credential", "x-goog-signature",
    ]

    private static func decodedName(_ name: String) -> String {
        var decoded = name
        for _ in 0 ..< 2 {
            guard let next = decoded.removingPercentEncoding, next != decoded else { break }
            decoded = next
        }
        return decoded.lowercased()
    }

    private static func effectivePort(_ components: URLComponents) -> Int? {
        if let port = components.port { return port }
        return switch components.scheme?.lowercased() {
        case "https": 443
        case "http": 80
        default: nil
        }
    }

    private static func normalizedPath(_ url: URL) throws -> String {
        guard let rawPath = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        )?.percentEncodedPath.lowercased(),
        !["%25", "%2f", "%5c"].contains(where: { rawPath.contains($0) })
        else {
            throw LatchwayError.invalidRequest(
                "The request URL path contains an encoded separator or percent escape"
            )
        }
        let htu = try LatchwayDPoPProofFactory.normalizedHTU(url)
        guard let path = URLComponents(string: htu)?.percentEncodedPath, !path.isEmpty else {
            throw LatchwayError.invalidRequest("The request URL path cannot be normalized")
        }
        return path
    }
}
