import Foundation
@testable import Latchway
import LatchwayTesting
import XCTest

final class LiveCoreConformanceTests: XCTestCase {
    func testSDKIssuesOneDebugAttestedProxiedRequest() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LATCHWAY_IOS_LIVE_CONFORMANCE"] == "1" else {
            throw XCTSkip("live core conformance is enabled only by the ordinary PR CI job")
        }

        let baseURL = try requiredURL("LATCHWAY_DEVELOP_BASE_URL", environment: environment)
        guard let baseComponents = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              baseComponents.scheme == "http",
              baseComponents.host == "127.0.0.1",
              let basePort = baseComponents.port,
              (1 ... 65_535).contains(basePort),
              baseComponents.percentEncodedPath.isEmpty,
              baseURL.absoluteString == "http://127.0.0.1:\(basePort)"
        else {
            throw LiveConformanceError.invalidEnvironment("the live test accepts only the isolated loopback development deployment")
        }
        let identityTokenURL = try requiredURL("LATCHWAY_DEVELOP_IDENTITY_TOKEN_URL", environment: environment)
        let evidenceURL = try requiredURL("LATCHWAY_DEVELOP_ATTESTATION_EVIDENCE_URL", environment: environment)
        guard identityTokenURL.absoluteString == baseURL.appendingPathComponent("development/v1/identity-token").absoluteString,
              evidenceURL.absoluteString == baseURL.appendingPathComponent("development/v1/attestation-evidence").absoluteString
        else {
            throw LiveConformanceError.invalidEnvironment("the development helper URLs are not bound to the gateway origin")
        }

        let applicationID = try required("LATCHWAY_DEVELOP_APPLICATION_ID", environment: environment)
        let deploymentEnvironment = try required("LATCHWAY_DEVELOP_ENVIRONMENT", environment: environment)
        let feature = try required("LATCHWAY_DEVELOP_FEATURE", environment: environment)
        let model = try required("LATCHWAY_DEVELOP_MODEL", environment: environment)
        let outputURL = URL(fileURLWithPath: try required("LATCHWAY_SDK_CONFORMANCE_OUTPUT", environment: environment))

        let key = try LatchwayDeterministicInstallationKey(
            rawPrivateKey: decodeBase64URL("2ZFd1bc5bCB8zu8OEf5l7O9x_SxbsQNQMNn0si4NxxI")
        )
        let thumbprint = try await LatchwayDPoPProofFactory(key: key).thumbprint()
        let attestation = LiveDebugAttestationProvider(
            evidenceURL: evidenceURL,
            applicationID: applicationID,
            environment: deploymentEnvironment,
            dpopThumbprint: thumbprint
        )
        let identity = LiveIdentityTokenProvider(url: identityTokenURL)
        let configuration = LatchwayConfiguration(
            baseURL: baseURL,
            applicationID: applicationID,
            environment: deploymentEnvironment,
            rootKeychainAccessGroup: "PRCONFORMANCE.dev.latchway.quickstart.ios",
            identityProvider: "mock_oidc",
            clientRuntime: .iOS,
            appVersion: "1.0.0-pr-conformance",
            attestationProvider: attestation
        )
        let sessionStorage = LatchwayInMemorySessionStorage()
        let client = LatchwayClient(
            configuration: configuration,
            identityTokenProvider: identity,
            attestationProvider: attestation,
            installationKey: key,
            sessionStorage: sessionStorage,
            transport: LatchwayURLSessionTransport(),
            clock: LatchwaySystemClock(),
            rootKeychainPreflight: {}
        )

        let quotaBefore = try await client.quota(feature: feature)
        guard quotaBefore.feature == feature, !quotaBefore.limits.isEmpty else {
            throw LiveConformanceError.failedCheck("the iOS SDK did not establish a session through its live quota API")
        }
        let firstDiagnostics = await client.diagnostics()
        guard firstDiagnostics.sessionState == .active,
              firstDiagnostics.trustProvider == "debug",
              firstDiagnostics.trustLevel == "debug",
              firstDiagnostics.attestation.support == .supported,
              firstDiagnostics.installationID != nil,
              firstDiagnostics.keyThumbprint == thumbprint,
              await attestation.evidenceCallCount == 1
        else {
            throw LiveConformanceError.failedCheck("the iOS SDK did not establish the expected debug-attested DPoP session")
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/responses"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "input": "One deterministic iOS SDK PR conformance request.",
            "max_output_tokens": 16,
        ], options: [.sortedKeys])
        let response = try await client.send(request, feature: feature)
        let responseDocument = try boundedJSONObject(response.body)
        let responseRequestID = response.header("X-Latchway-Request-ID")
        let outputText = ((responseDocument["output"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])?.first
        let usage = responseDocument["usage"] as? [String: Any]
        guard response.statusCode == 200,
              responseDocument["id"] as? String == "resp_mock_0001",
              responseDocument["model"] as? String == "latchway-mock-model",
              responseDocument["status"] as? String == "completed",
              outputText?["type"] as? String == "output_text",
              outputText?["text"] as? String == "Deterministic mock response.",
              (usage?["input_tokens"] as? NSNumber)?.intValue == 11,
              (usage?["output_tokens"] as? NSNumber)?.intValue == 7,
              (usage?["total_tokens"] as? NSNumber)?.intValue == 18,
              let responseRequestID,
              responseRequestID.utf8.count >= 8
        else {
            throw LiveConformanceError.failedCheck("the iOS SDK did not complete the deterministic proxied mock request")
        }

        let quota = try await client.quota(feature: feature)
        let requestLimitBefore = quotaBefore.limits.first { $0.metric == "logical_requests" }
        let requestLimit = quota.limits.first { $0.metric == "logical_requests" }
        guard quota.feature == feature,
              !quota.limits.isEmpty,
              quota.limits.allSatisfy({ !$0.metric.isEmpty && $0.hard }),
              let requestLimitBefore,
              let requestLimit,
              let usedBefore = requestLimitBefore.used,
              let used = requestLimit.used,
              used == usedBefore + 1,
              let remainingBefore = requestLimitBefore.remaining,
              let remaining = requestLimit.remaining,
              remaining == remainingBefore - 1
        else {
            throw LiveConformanceError.failedCheck("the iOS SDK returned an invalid live quota snapshot")
        }

        let storedBeforeRefresh = try await sessionStorage.load()
        try await client.refresh()
        let storedAfterRefresh = try await sessionStorage.load()
        let refreshedDiagnostics = await client.diagnostics()
        guard refreshedDiagnostics.sessionState == .active,
              refreshedDiagnostics.installationID == firstDiagnostics.installationID,
              let storedBeforeRefresh,
              let storedAfterRefresh,
              storedAfterRefresh.installation.id == storedBeforeRefresh.installation.id,
              storedAfterRefresh.refreshToken != storedBeforeRefresh.refreshToken,
              await attestation.evidenceCallCount == 1,
              await key.signatureCount > 0
        else {
            throw LiveConformanceError.failedCheck("the iOS SDK did not preserve its installation across an explicit DPoP session refresh")
        }

        let report: [String: Any] = [
            "schema_version": 1,
            "kind": "latchway_sdk_live_debug_conformance",
            "sdk_kind": "ios",
            "status": "passed",
            "physical_attestation_claimed": false,
            "checks": [
                "debug_attestation": true,
                "dpop_session": true,
                "proxied_mock_request": true,
                "quota": true,
                "session_refresh": true,
            ],
            "observations": [
                "platform": "ios",
                "trust_provider": firstDiagnostics.trustProvider ?? "",
                "contract_version": firstDiagnostics.contractVersion,
                "protocol_version": firstDiagnostics.protocolVersion,
                "response_request_id": responseRequestID,
                "quota_limit_count": quota.limits.count,
                "logical_requests_delta": 1,
            ],
        ]
        let reportData = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try (reportData + Data("\n".utf8)).write(to: outputURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)
    }

    private func required(_ name: String, environment: [String: String]) throws -> String {
        guard let value = environment[name], !value.isEmpty, value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw LiveConformanceError.invalidEnvironment("\(name) is required")
        }
        return value
    }

    private func requiredURL(_ name: String, environment: [String: String]) throws -> URL {
        let value = try required(name, environment: environment)
        guard let url = URL(string: value),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else { throw LiveConformanceError.invalidEnvironment("\(name) must be one credential-free absolute URL") }
        return url
    }

    private func decodeBase64URL(_ value: String) throws -> Data {
        guard !value.contains("=") else { throw LiveConformanceError.invalidEnvironment("the deterministic key is not canonical base64url") }
        var padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        padded += String(repeating: "=", count: (4 - padded.count % 4) % 4)
        guard let data = Data(base64Encoded: padded) else {
            throw LiveConformanceError.invalidEnvironment("the deterministic key is not valid base64url")
        }
        return data
    }

    private func boundedJSONObject(_ data: Data) throws -> [String: Any] {
        guard !data.isEmpty, data.count <= 131_072,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw LiveConformanceError.failedCheck("the live response was not one bounded JSON object") }
        return object
    }
}

private actor LiveIdentityTokenProvider: LatchwayIdentityTokenProvider {
    private let url: URL

    init(url: URL) { self.url = url }

    func identityToken() async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              !data.isEmpty, data.count <= 131_072,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["identity_token"],
              let token = object["identity_token"] as? String,
              token.utf8.count >= 64
        else { throw LiveConformanceError.failedCheck("the development identity helper returned an invalid document") }
        return token
    }
}

private actor LiveDebugAttestationProvider: LatchwayAttestationProvider {
    private let evidenceURL: URL
    private let applicationID: String
    private let environment: String
    private let dpopThumbprint: String
    private(set) var evidenceCallCount = 0
    private var keyID: String?

    init(evidenceURL: URL, applicationID: String, environment: String, dpopThumbprint: String) {
        self.evidenceURL = evidenceURL
        self.applicationID = applicationID
        self.environment = environment
        self.dpopThumbprint = dpopThumbprint
    }

    func evidence(for challenge: LatchwayAttestationChallenge) async throws -> LatchwayAttestationEvidence {
        guard challenge.provider == "debug" else {
            throw LiveConformanceError.failedCheck("the development challenge did not require the debug provider")
        }
        evidenceCallCount += 1
        let bindingHash = base64URL(challenge.clientDataHash)
        var request = URLRequest(url: evidenceURL)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "challenge_id": challenge.id,
            "binding_hash": bindingHash,
            "application_id": applicationID,
            "environment": environment,
            "dpop_jkt": dpopThumbprint,
            "platform": "ios",
        ], options: [.sortedKeys])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              !data.isEmpty, data.count <= 131_072,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["binding_hash", "expires_at", "key_id", "signature"],
              object["binding_hash"] as? String == bindingHash,
              let keyID = object["key_id"] as? String, !keyID.isEmpty,
              let expiresAt = object["expires_at"] as? NSNumber,
              let signature = object["signature"] as? String, !signature.isEmpty
        else { throw LiveConformanceError.failedCheck("the development attestation helper returned invalid evidence") }
        self.keyID = keyID
        return LatchwayAttestationEvidence(provider: "debug", evidence: [
            "binding_hash": .string(bindingHash),
            "expires_at": .number(expiresAt.decimalValue),
            "key_id": .string(keyID),
            "signature": .string(signature),
        ])
    }

    func didAccept(_: LatchwayAttestationEvidence) async {}

    func reset() async throws {
        evidenceCallCount = 0
        keyID = nil
    }

    func status() async -> LatchwayAttestationStatus {
        LatchwayAttestationStatus(support: .supported, keyID: keyID, lastOperation: "debug_ci")
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private enum LiveConformanceError: Error {
    case invalidEnvironment(String)
    case failedCheck(String)
}
