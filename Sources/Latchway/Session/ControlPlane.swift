import Foundation

struct LatchwayControlPlane: Sendable {
    let configuration: LatchwayConfiguration
    let transport: any LatchwayHTTPTransport
    let proofFactory: LatchwayDPoPProofFactory
    let clock: any LatchwayClock

    private enum Endpoint {
        static let sessionChallenges = "client/v1/session-challenges"
        static let sessions = "client/v1/sessions"
        static let sessionRefresh = "client/v1/sessions/refresh"
        static let currentInstallation = "client/v1/installations/current"
        static let currentInstallationFamily = "client/v1/installation-families/current"
        static let currentFamilyComponents = "client/v1/installation-families/current/components"
        static let componentSessions = "client/v1/component-sessions"
        static let diagnostics = "client/v1/diagnostics"

        static func quota(feature: String) -> String {
            "client/v1/features/\(feature)/quota"
        }

        static func component(_ componentID: String) -> String {
            "\(currentFamilyComponents)/\(componentID)"
        }
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .latchwayISO8601
        return decoder
    }

    func createChallenge(identityToken: String) async throws -> SessionChallengeWire {
        let body = SessionChallengeRequest(
            applicationID: configuration.applicationID,
            environment: configuration.environment,
            identityProvider: configuration.identityProvider,
            identityToken: identityToken,
            platform: configuration.clientRuntime.platformIdentifier,
            sdkVersion: configuration.clientSDKVersion
        )
        return try await sendJSON(
            method: "POST",
            path: Endpoint.sessionChallenges,
            body: body,
            accessToken: nil,
            expectedStatus: 201,
            as: SessionChallengeWire.self
        )
    }

    func exchange(challengeID: String, evidence: LatchwayAttestationEvidence) async throws -> SessionGrantWire {
        let process = ProcessInfo.processInfo
        let body = SessionExchangeRequest(
            challengeID: challengeID,
            attestation: evidence,
            installation: .init(
                appVersion: configuration.appVersion,
                osVersion: process.operatingSystemVersionString,
                deviceModel: Self.deviceModel
            )
        )
        return try await sendJSON(
            method: "POST",
            path: Endpoint.sessions,
            body: body,
            accessToken: nil,
            expectedStatus: 201,
            as: SessionGrantWire.self
        )
    }

    func refresh(refreshToken: String) async throws -> SessionGrantWire {
        try await sendJSON(
            method: "POST",
            path: Endpoint.sessionRefresh,
            body: SessionRefreshRequest(refreshToken: refreshToken),
            accessToken: nil,
            expectedStatus: 200,
            as: SessionGrantWire.self
        )
    }

    func quota(feature: String, accessToken: String) async throws -> LatchwayQuotaSnapshot {
        let encodedFeature = try Self.pathComponent(feature)
        return try await sendWithoutBody(
            method: "GET",
            path: Endpoint.quota(feature: encodedFeature),
            accessToken: accessToken,
            expectedStatus: 200,
            as: LatchwayQuotaSnapshot.self
        )
    }

    func diagnostics(accessToken: String) async throws -> ClientDiagnosticsWire {
        try await sendWithoutBody(
            method: "GET",
            path: Endpoint.diagnostics,
            accessToken: accessToken,
            expectedStatus: 200,
            as: ClientDiagnosticsWire.self
        )
    }

    func revoke(accessToken: String) async throws {
        let response = try await sendAuthorized(
            method: "DELETE",
            path: Endpoint.currentInstallation,
            accessToken: accessToken,
            body: nil
        )
        guard response.statusCode == 204, response.body.isEmpty else { throw try error(from: response) }
    }

    func revokeFamily(accessToken: String) async throws {
        let response = try await sendAuthorized(
            method: "DELETE",
            path: Endpoint.currentInstallationFamily,
            accessToken: accessToken,
            body: nil
        )
        guard response.statusCode == 204, response.body.isEmpty else { throw try error(from: response) }
    }

    func provisionComponent(
        definitionID: String,
        publicJWK: LatchwayPublicJWK,
        requestedFeatures: [String],
        accessToken: String
    ) async throws -> ComponentProvisioningWire {
        try await sendJSON(
            method: "POST",
            path: Endpoint.currentFamilyComponents,
            body: ComponentProvisioningRequest(
                componentDefinitionID: definitionID,
                publicJWK: publicJWK,
                requestedFeatures: requestedFeatures,
                clientMetadata: .init(
                    appVersion: configuration.appVersion,
                    sdkVersion: configuration.clientSDKVersion
                )
            ),
            accessToken: accessToken,
            expectedStatus: 201,
            as: ComponentProvisioningWire.self
        )
    }

    func createComponentSession(
        componentID: String,
        refreshGrant: String
    ) async throws -> ComponentSessionGrantWire {
        try await sendJSON(
            method: "POST",
            path: Endpoint.componentSessions,
            body: ComponentSessionRequest(componentID: componentID, refreshGrant: refreshGrant),
            accessToken: nil,
            expectedStatus: 201,
            as: ComponentSessionGrantWire.self
        )
    }

    func refreshComponent(refreshToken: String) async throws -> ComponentSessionGrantWire {
        try await sendJSON(
            method: "POST",
            path: Endpoint.sessionRefresh,
            body: SessionRefreshRequest(refreshToken: refreshToken),
            accessToken: nil,
            expectedStatus: 200,
            as: ComponentSessionGrantWire.self
        )
    }

    func revokeComponent(componentID: String, accessToken: String) async throws {
        let encodedID = try Self.resourceID(componentID, prefix: "cmp")
        let response = try await sendAuthorized(
            method: "DELETE",
            path: Endpoint.component(encodedID),
            accessToken: accessToken,
            body: nil
        )
        guard response.statusCode == 204, response.body.isEmpty else { throw try error(from: response) }
    }

    private func sendJSON<Body: Encodable, Response: Decodable>(
        method: String,
        path: String,
        body: Body,
        accessToken: String?,
        expectedStatus: Int,
        as _: Response.Type
    ) async throws -> Response {
        let data: Data
        do { data = try encoder.encode(body) }
        catch { throw LatchwayError.invalidRequest("The request body could not be encoded") }
        let response = try await sendAuthorized(method: method, path: path, accessToken: accessToken, body: data)
        return try decode(response, expectedStatus: expectedStatus, as: Response.self)
    }

    private func sendWithoutBody<Response: Decodable>(
        method: String,
        path: String,
        accessToken: String,
        expectedStatus: Int,
        as _: Response.Type
    ) async throws -> Response {
        let response = try await sendAuthorized(method: method, path: path, accessToken: accessToken, body: nil)
        return try decode(response, expectedStatus: expectedStatus, as: Response.self)
    }

    private func sendAuthorized(
        method: String,
        path: String,
        accessToken: String?,
        body: Data?
    ) async throws -> LatchwayHTTPResponse {
        let url = try endpoint(path)
        var nonce: String?
        let requestID = UUID().uuidString.lowercased()
        for attempt in 0 ... 1 {
            var request = URLRequest(url: url, timeoutInterval: configuration.controlRequestTimeout)
            request.httpMethod = method
            request.httpBody = body
            if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            request.setValue("application/problem+json, application/json", forHTTPHeaderField: "Accept")
            request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
            request.setValue(requestID, forHTTPHeaderField: "X-Latchway-Request-ID")
            addStandardHeaders(to: &request)
            if let accessToken { request.setValue("DPoP \(accessToken)", forHTTPHeaderField: "Authorization") }
            let proof = try await proofFactory.proof(method: method, url: url, accessToken: accessToken, nonce: nonce)
            request.setValue(proof, forHTTPHeaderField: "DPoP")

            let response = try await transport.send(request)
            if attempt == 0,
               case let .dpopNonceRequired(suppliedNonce) = SafeRetryDirective.parse(
                   response: response,
                   expectedRequestID: requestID
               ) {
                nonce = suppliedNonce
                continue
            }
            return response
        }
        throw LatchwayError.invalidServerResponse
    }

    private func decode<Response: Decodable>(
        _ response: LatchwayHTTPResponse,
        expectedStatus: Int,
        as _: Response.Type
    ) throws -> Response {
        guard response.statusCode == expectedStatus else { throw try error(from: response) }
        guard Self.mediaType(response.header("Content-Type")) == "application/json" else {
            throw LatchwayError.invalidServerResponse
        }
        do {
            try StrictJSON.validate(response.body)
            return try decoder.decode(Response.self, from: response.body)
        }
        catch { throw LatchwayError.invalidServerResponse }
    }

    private func error(from response: LatchwayHTTPResponse) throws -> LatchwayError {
        guard (400 ... 599).contains(response.statusCode) else { return .invalidServerResponse }
        return .server(try decodeProblem(response))
    }

    private func decodeProblem(_ response: LatchwayHTTPResponse) throws -> LatchwayProblem {
        guard response.body.count <= 65_536,
              Self.mediaType(response.header("Content-Type")) == "application/problem+json"
        else { throw LatchwayError.invalidServerResponse }
        do {
            try StrictJSON.validate(response.body)
            let wire = try decoder.decode(ProblemWire.self, from: response.body)
            guard wire.isValid,
                  response.header("X-Latchway-Request-ID") == nil
                      || response.header("X-Latchway-Request-ID") == wire.requestID
            else { throw LatchwayError.invalidServerResponse }
            let problem = wire.problem
            guard problem.status == response.statusCode else { throw LatchwayError.invalidServerResponse }
            return problem
        } catch let error as LatchwayError { throw error }
        catch { throw LatchwayError.invalidServerResponse }
    }

    private func endpoint(_ path: String) throws -> URL {
        guard configuration.baseURL.query == nil,
              configuration.baseURL.fragment == nil,
              configuration.baseURL.user == nil,
              configuration.baseURL.password == nil,
              let scheme = configuration.baseURL.scheme?.lowercased(),
              let host = configuration.baseURL.host,
              !host.isEmpty
        else { throw LatchwayError.invalidConfiguration("baseURL must be an absolute origin or path without query, fragment, or user information") }
        let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && loopback) else {
            throw LatchwayError.invalidConfiguration("baseURL must use HTTPS except for loopback development")
        }
        return configuration.baseURL.appendingPathComponent(path)
    }

    private func addStandardHeaders(to request: inout URLRequest) {
        request.setValue(configuration.clientRuntime.sdkIdentifier, forHTTPHeaderField: "X-Latchway-SDK")
        request.setValue(configuration.clientSDKVersion, forHTTPHeaderField: "X-Latchway-SDK-Version")
        request.setValue(String(LatchwayVersion.protocolVersion), forHTTPHeaderField: "X-Latchway-Protocol-Version")
        if request.value(forHTTPHeaderField: "X-Latchway-Request-ID") == nil {
            request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Latchway-Request-ID")
        }
    }

    private static func pathComponent(_ value: String) throws -> String {
        guard value.range(of: "^[a-z][a-z0-9_-]{0,62}$", options: .regularExpression) != nil else {
            throw LatchwayError.invalidRequest("feature must be a valid Latchway identifier")
        }
        return value
    }

    private static func resourceID(_ value: String, prefix: String) throws -> String {
        guard value.range(
            of: "^\(prefix)_[A-Za-z0-9_-]{16,128}$",
            options: .regularExpression
        ) != nil else {
            throw LatchwayError.invalidRequest("resource identifier is invalid")
        }
        return value
    }

    private static func mediaType(_ value: String?) -> String? {
        value?
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static var deviceModel: String {
        #if canImport(UIKit)
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
        #else
        return "mac"
        #endif
    }
}

private extension JSONDecoder.DateDecodingStrategy {
    static var latchwayISO8601: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Expected RFC 3339 date-time")
        }
    }
}
