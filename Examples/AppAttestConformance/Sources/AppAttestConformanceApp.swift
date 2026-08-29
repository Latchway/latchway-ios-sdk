import Darwin
import Foundation
import Latchway
import LatchwayAppAttest
import SwiftUI

@main
struct AppAttestConformanceApp: App {
    @StateObject private var model = ConformanceModel()

    var body: some Scene {
        WindowGroup {
            NavigationView {
                List {
                    Section("Device security") {
                        StatusRow(label: "Identity", value: model.identityStatus)
                        StatusRow(label: "Secure Enclave", value: model.secureEnclaveStatus)
                        StatusRow(label: "App Attest", value: model.appAttestSupport)
                        StatusRow(label: "App Attest key", value: model.appAttestKeyID)
                    }
                    Section("Conformance") {
                        StatusRow(label: "Attestation", value: model.attestationResult)
                        StatusRow(label: "Session", value: model.sessionResult)
                        StatusRow(label: "DPoP replay", value: model.replayResult)
                        StatusRow(label: "DPoP tamper", value: model.tamperResult)
                        StatusRow(label: "Streamed request", value: model.requestResult)
                        StatusRow(label: "Quota", value: model.quotaResult)
                        StatusRow(label: "Installation", value: model.installationID)
                        StatusRow(label: "Evidence", value: model.evidenceResult)
                    }
                    Section {
                        Button(model.running ? "Running…" : "Run physical release suite") {
                            Task { await model.runReleaseSuite() }
                        }
                        .disabled(model.running)
                    }
                }
                .navigationTitle("Latchway Conformance")
                .task {
                    if ProcessInfo.processInfo.environment["LATCHWAY_CONFORMANCE_AUTORUN"] == "1" {
                        await model.runReleaseSuite()
                    }
                }
            }
        }
    }
}

private struct StatusRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }
}

@MainActor
private final class ConformanceModel: ObservableObject {
    @Published var identityStatus = "not checked"
    @Published var secureEnclaveStatus = "not checked"
    @Published var appAttestSupport = "not checked"
    @Published var appAttestKeyID = "redacted"
    @Published var attestationResult = "not run"
    @Published var sessionResult = "not run"
    @Published var replayResult = "not run"
    @Published var tamperResult = "not run"
    @Published var requestResult = "not run"
    @Published var quotaResult = "not run"
    @Published var installationID = "none"
    @Published var evidenceResult = "not written"
    @Published var running = false

    func runReleaseSuite() async {
        guard !running else { return }
        running = true
        defer { running = false }

        let startedAt = Self.timestamp()
        let environment = ProcessInfo.processInfo.environment
        guard let values = Values(environment: environment) else {
            identityStatus = "missing or invalid launch configuration"
            return
        }
        identityStatus = "configured"

        var tests: [EvidenceTest] = [
            .boolean(
                id: "physical_device",
                passed: DeviceFacts.physical
                    && !DeviceFacts.simulator
                    && !DeviceFacts.testing
                    && !DeviceFacts.debuggerAttached
            ),
            .boolean(id: "identifier_pins", passed: values.localPinsMatch),
        ]

        let appAttest = LatchwayAppAttestProvider(
            applicationID: values.applicationID,
            environment: values.environment,
            clientRuntime: .iOS
        )
        do {
            guard environment["LATCHWAY_RESET_INSTALLATION"] == "1" else {
                throw SuiteError.configuration
            }
            try await LatchwayKeychainSessionStorage(
                applicationID: values.applicationID,
                environment: values.environment,
                clientRuntime: .iOS
            ).clear()
            try await appAttest.reset()
            try await LatchwayInstallationKeyManager(
                applicationID: values.applicationID,
                environment: values.environment,
                clientRuntime: .iOS,
                softwareFallbackPolicy: .disallow
            ).reset()
        } catch {
            tests.append(.failed(id: "app_attest_registration"))
            attestationResult = "fresh-key reset failed"
            await writeObservation(values: values, startedAt: startedAt, tests: tests, diagnostics: nil)
            return
        }

        let client = makeClient(values: values, appAttest: appAttest)
        var diagnostics: LatchwayDiagnostics?
        do {
            let probe = try await authorizedQuotaProbe(client: client, values: values)
            let first = try await sendBounded(probe, maximumBytes: 65_536)
            tests.append(.http(
                id: "dpop_authorized_request",
                passed: (200 ..< 300).contains(first.status),
                response: first
            ))

            diagnostics = await client.diagnostics()
            if let diagnostics {
                secureEnclaveStatus = diagnostics.keyStorage.rawValue
                appAttestSupport = diagnostics.attestation.support.rawValue
                appAttestKeyID = diagnostics.attestation.keyID == nil ? "none" : "present (redacted)"
                attestationResult = diagnostics.attestation.lastOperation ?? "unknown"
                sessionResult = diagnostics.sessionState.rawValue
                installationID = diagnostics.installationID ?? "none"
                tests.append(.boolean(id: "app_attest_supported", passed: diagnostics.attestation.support == .supported))
                tests.append(.boolean(id: "secure_enclave_key", passed: diagnostics.keyStorage == .secureEnclave))
                tests.append(.boolean(id: "app_attest_registration", passed: diagnostics.attestation.lastOperation == "attestation"))
                tests.append(.boolean(id: "session_created", passed: diagnostics.sessionState == .active))
            }

            let replay = try await sendBounded(probe, maximumBytes: 65_536)
            let replayPassed = replay.status == 401 && replay.problemCode == "dpop_replayed"
            tests.append(.http(id: "dpop_replay_rejected", passed: replayPassed, response: replay))
            replayResult = replayPassed ? "passed" : "failed"

            var tampered = try await authorizedQuotaProbe(client: client, values: values)
            guard let proof = tampered.value(forHTTPHeaderField: "DPoP"), !proof.isEmpty else {
                throw SuiteError.protocolFailure
            }
            tampered.setValue(try tamperedDPoPProof(proof), forHTTPHeaderField: "DPoP")
            let tamper = try await sendBounded(tampered, maximumBytes: 65_536)
            let tamperPassed = tamper.status == 401 && tamper.problemCode == "dpop_invalid"
            tests.append(.http(id: "tampered_dpop_rejected", passed: tamperPassed, response: tamper))
            tamperResult = tamperPassed ? "passed" : "failed"

            let stream = try await streamedRequest(client: client, values: values)
            tests.append(.http(
                id: "streamed_request",
                passed: (200 ..< 300).contains(stream.status) && stream.byteCount > 0,
                response: stream
            ))
            requestResult = (200 ..< 300).contains(stream.status)
                ? "passed (\(stream.byteCount) bytes)"
                : "failed"

            let snapshot = try await client.quota(feature: values.feature)
            let quotaPassed = snapshot.feature == values.feature && !snapshot.limits.isEmpty
            tests.append(.boolean(id: "quota", passed: quotaPassed))
            quotaResult = quotaPassed ? "passed (\(snapshot.limits.count) limits)" : "failed"

            try await LatchwayKeychainSessionStorage(
                applicationID: values.applicationID,
                environment: values.environment,
                clientRuntime: .iOS
            ).clear()
            let assertionProvider = LatchwayAppAttestProvider(
                applicationID: values.applicationID,
                environment: values.environment,
                clientRuntime: .iOS
            )
            let assertionClient = makeClient(values: values, appAttest: assertionProvider)
            _ = try await assertionClient.quota(feature: values.feature)
            let assertionDiagnostics = await assertionClient.diagnostics()
            let assertionPassed = assertionDiagnostics.attestation.lastOperation == "assertion"
                && assertionDiagnostics.sessionState == .active
                && assertionDiagnostics.installationID == diagnostics?.installationID
            tests.append(.boolean(id: "app_attest_assertion", passed: assertionPassed))
            attestationResult = assertionPassed ? "registration + assertion" : "assertion failed"
        } catch {
            let missing = EvidencePolicy.iosTests.subtracting(tests.map(\.id))
            tests.append(contentsOf: missing.sorted().map { .failed(id: $0) })
            requestResult = "failed"
            if replayResult == "not run" { replayResult = "failed" }
            if tamperResult == "not run" { tamperResult = "failed" }
        }

        await writeObservation(
            values: values,
            startedAt: startedAt,
            tests: tests,
            diagnostics: diagnostics
        )
    }

    private func makeClient(
        values: Values,
        appAttest: LatchwayAppAttestProvider
    ) -> LatchwayClient {
        LatchwayClient(
            configuration: LatchwayConfiguration(
                baseURL: values.gateway,
                applicationID: values.applicationID,
                environment: values.environment,
                identityProvider: values.identityProvider,
                appVersion: values.appVersion,
                softwareKeyFallbackPolicy: .disallow,
                attestationProvider: appAttest
            ),
            identityTokenProvider: ConformanceIdentityProvider(token: values.identityToken)
        )
    }

    private func authorizedQuotaProbe(client: LatchwayClient, values: Values) async throws -> URLRequest {
        let url = values.gateway
            .appendingPathComponent("client")
            .appendingPathComponent("v1")
            .appendingPathComponent("features")
            .appendingPathComponent(values.feature)
            .appendingPathComponent("quota")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try await client.authorize(&request, feature: values.feature)
        return request
    }

    private func streamedRequest(client: LatchwayClient, values: Values) async throws -> HTTPObservation {
        let url = values.gateway.appendingPathComponent("v1").appendingPathComponent("chat").appendingPathComponent("completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "model": values.model,
            "stream": true,
            "messages": [["role": "user", "content": "Return the word conformance."]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        try await client.authorize(&request, feature: values.feature)
        return try await sendBounded(request, maximumBytes: 1_048_576)
    }

    private func writeObservation(
        values: Values,
        startedAt: String,
        tests: [EvidenceTest],
        diagnostics: LatchwayDiagnostics?
    ) async {
        let allTests = EvidencePolicy.iosTests.sorted().map { required in
            tests.first(where: { $0.id == required }) ?? .failed(id: required)
        }
        let trustLevel = diagnostics?.trustLevel ?? "none"
        let requestHashBound = diagnostics?.trustProvider == "app_attest"
            && ["device_verified", "strong_device_verified"].contains(trustLevel)
        let document = DeviceObservation(
            schemaVersion: "latchway.physical-device-observation.v1",
            platform: "ios_app_attest",
            run: .init(
                id: values.runID,
                mode: "release",
                startedAt: startedAt,
                completedAt: Self.timestamp()
            ),
            gatewayVersion: diagnostics?.serverVersion ?? "unknown",
            application: .init(
                identifier: Bundle.main.bundleIdentifier ?? "unknown",
                version: values.appVersion,
                build: values.buildNumber,
                buildMode: DeviceFacts.debugBuild ? "debug" : "release",
                distribution: values.distribution,
                debuggable: DeviceFacts.debugBuild || DeviceFacts.debuggerAttached,
                signingCertificateSHA256: values.signingCertificateSHA256,
                teamID: values.teamID,
                appAttestEnvironment: values.appAttestEnvironment
            ),
            device: .init(
                physical: DeviceFacts.physical,
                simulator: DeviceFacts.simulator,
                emulator: false,
                testing: DeviceFacts.testing,
                debuggerAttached: DeviceFacts.debuggerAttached,
                model: DeviceFacts.model,
                osName: "iOS",
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                osBuild: DeviceFacts.osBuild,
                securityLevel: diagnostics?.keyStorage == .secureEnclave ? "secure_enclave" : "unknown"
            ),
            provider: .init(
                name: "app_attest",
                environment: values.appAttestEnvironment,
                trustLevel: trustLevel,
                requestHashBound: requestHashBound,
                appRecognition: "not_applicable",
                accountLicensing: "not_applicable"
            ),
            observedPins: values.observedPins,
            tests: allTests,
            redaction: .init()
        )
        do {
            let data = try JSONEncoder.evidence.encode(document)
            guard data.count <= 262_144 else { throw SuiteError.protocolFailure }
            let directory = try FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let output = directory.appendingPathComponent("latchway-device-observation.json")
            try data.write(to: output, options: [.atomic, .completeFileProtection])
            evidenceResult = allTests.allSatisfy { $0.status == "passed" }
                ? "written (validator required)"
                : "written with failures"
        } catch {
            evidenceResult = "write failed"
        }
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: Date())
    }
}

private struct Values {
    let gateway: URL
    let applicationID: String
    let environment: String
    let identityProvider: String
    let identityToken: String
    let feature: String
    let model: String
    let runID: String
    let distribution: String
    let appVersion: String
    let buildNumber: String
    let teamID: String
    let signingCertificateSHA256: String
    let appAttestEnvironment: String
    let observedPins: [String: String]

    init?(environment values: [String: String]) {
        guard let gatewayText = values["LATCHWAY_BASE_URL"],
              let gateway = URL(string: gatewayText), gateway.scheme == "https", gateway.host != nil,
              let gatewayOrigin = values.bounded("LATCHWAY_GATEWAY_ORIGIN", maximum: 512),
              gatewayText == gatewayOrigin,
              let applicationID = values.canonical(
                  "LATCHWAY_APPLICATION_ID",
                  pattern: "^app_[0-7][0-9A-HJKMNP-TV-Z]{25}$"
              ),
              let environment = values.canonical("LATCHWAY_ENVIRONMENT", pattern: "^[a-z][a-z0-9_-]{0,62}$"),
              let identityToken = values["LATCHWAY_IDENTITY_TOKEN"], (16 ... 65_536).contains(identityToken.utf8.count),
              let feature = values.canonical("LATCHWAY_FEATURE", pattern: "^[a-z][a-z0-9_-]{0,62}$"),
              let model = values.bounded("LATCHWAY_MODEL", maximum: 256),
              let runID = values.canonical("LATCHWAY_RUN_ID", pattern: "^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$"),
              let distribution = values.canonical("LATCHWAY_DISTRIBUTION", pattern: "^(ad_hoc|testflight|app_store)$"),
              let teamID = values.canonical("LATCHWAY_TEAM_ID", pattern: "^[A-Z0-9]{10}$"),
              let signingCertificate = values.canonical("LATCHWAY_SIGNING_CERTIFICATE_SHA256", pattern: "^[0-9a-f]{64}$"),
              let sourceCommit = values.canonical("LATCHWAY_SOURCE_COMMIT", pattern: "^[0-9a-f]{40}$"),
              let coreCommit = values.canonical("LATCHWAY_CORE_COMMIT", pattern: "^[0-9a-f]{40}$"),
              let contractHash = values.canonical("LATCHWAY_CONTRACT_BUNDLE_SHA256", pattern: "^[0-9a-f]{64}$"),
              let gatewayDigest = values.canonical("LATCHWAY_GATEWAY_IMAGE_DIGEST", pattern: "^sha256:[0-9a-f]{64}$"),
              let configurationHash = values.canonical("LATCHWAY_GATEWAY_CONFIGURATION_SHA256", pattern: "^[0-9a-f]{64}$"),
              let deploymentKeyID = values.canonical(
                  "LATCHWAY_GATEWAY_DEPLOYMENT_KEY_ID",
                  pattern: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"
              ),
              let deploymentStatementHash = values.canonical(
                  "LATCHWAY_GATEWAY_DEPLOYMENT_STATEMENT_SHA256",
                  pattern: "^[0-9a-f]{64}$"
              ),
              let deploymentPublicKeyHash = values.canonical(
                  "LATCHWAY_GATEWAY_DEPLOYMENT_PUBLIC_KEY_SHA256",
                  pattern: "^[0-9a-f]{64}$"
              ),
              let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let appAttestEnvironment = Bundle.main.object(forInfoDictionaryKey: "LatchwayAppAttestEnvironment") as? String,
              let identifier = Bundle.main.bundleIdentifier
        else { return nil }
        self.gateway = gateway
        self.applicationID = applicationID
        self.environment = environment
        self.identityProvider = values["LATCHWAY_IDENTITY_PROVIDER"] ?? "firebase"
        self.identityToken = identityToken
        self.feature = feature
        self.model = model
        self.runID = runID
        self.distribution = distribution
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.teamID = teamID
        self.signingCertificateSHA256 = signingCertificate
        self.appAttestEnvironment = appAttestEnvironment
        self.observedPins = [
            "application_identifier": identifier,
            "app_version": appVersion,
            "build_number": buildNumber,
            "team_id": teamID,
            "signing_certificate_sha256": signingCertificate,
            "app_attest_environment": appAttestEnvironment,
            "source_commit": sourceCommit,
            "core_commit": coreCommit,
            "contract_bundle_sha256": contractHash,
            "gateway_image_digest": gatewayDigest,
            "gateway_configuration_sha256": configurationHash,
            "gateway_origin": gatewayOrigin,
            "gateway_environment": environment,
            "gateway_deployment_key_id": deploymentKeyID,
            "gateway_deployment_statement_sha256": deploymentStatementHash,
            "gateway_deployment_public_key_sha256": deploymentPublicKeyHash,
        ]
    }

    var localPinsMatch: Bool {
        observedPins["application_identifier"] == Bundle.main.bundleIdentifier
            && observedPins["app_version"] == appVersion
            && observedPins["build_number"] == buildNumber
            && appAttestEnvironment == "production"
    }
}

private struct HTTPObservation {
    let status: Int
    let body: Data
    let byteCount: Int
    let problemCode: String?
    let requestID: String?
}

/// Changes the first Base64URL character of the ES256 signature. Mutating the
/// final character is not sufficient: for an unpadded 64-byte signature its
/// low four bits are unused and permissive decoders may recover identical
/// bytes. This position always changes signature material while preserving a
/// syntactically valid compact JWT.
private func tamperedDPoPProof(_ proof: String) throws -> String {
    let segments = proof.split(separator: ".", omittingEmptySubsequences: false)
    guard segments.count == 3, !segments[0].isEmpty, !segments[1].isEmpty, !segments[2].isEmpty else {
        throw SuiteError.protocolFailure
    }
    let signature = String(segments[2])
    let replacement: Character = signature.first == "A" ? "B" : "A"
    return "\(segments[0]).\(segments[1]).\(replacement)\(signature.dropFirst())"
}

private func sendBounded(_ request: URLRequest, maximumBytes: Int) async throws -> HTTPObservation {
    let session = IsolatedSession.make()
    defer { session.invalidateAndCancel() }
    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse else { throw SuiteError.protocolFailure }
    var body = Data()
    for try await byte in bytes {
        guard body.count < maximumBytes else { throw SuiteError.protocolFailure }
        body.append(byte)
    }
    let mediaType = http.value(forHTTPHeaderField: "Content-Type")?
        .split(separator: ";", maxSplits: 1).first?.lowercased()
    let object = mediaType == "application/problem+json"
        ? (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        : nil
    let bodyStatus = object?["status"] as? Int
    let code = object?["code"] as? String
    let type = object?["type"] as? String
    let bodyRequestID = object?["request_id"] as? String
    let headerRequestID = http.value(forHTTPHeaderField: "X-Latchway-Request-ID")
    let validProblem = bodyStatus == http.statusCode
        && bodyRequestID == headerRequestID
        && type == code.map { "https://latchway.dev/problems/\($0)" }
    return HTTPObservation(
        status: http.statusCode,
        body: body,
        byteCount: body.count,
        problemCode: validProblem ? code : nil,
        requestID: validProblem ? bodyRequestID : headerRequestID
    )
}

private enum IsolatedSession {
    static func make() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }
}

private struct EvidenceTest: Codable {
    let id: String
    let status: String
    let durationMS: Int
    let httpStatus: Int?
    let errorCode: String?
    let requestID: String?

    enum CodingKeys: String, CodingKey {
        case id, status
        case durationMS = "duration_ms"
        case httpStatus = "http_status"
        case errorCode = "error_code"
        case requestID = "request_id"
    }

    static func boolean(id: String, passed: Bool) -> Self {
        Self(id: id, status: passed ? "passed" : "failed", durationMS: 0, httpStatus: nil, errorCode: nil, requestID: nil)
    }

    static func failed(id: String) -> Self { boolean(id: id, passed: false) }

    static func http(id: String, passed: Bool, response: HTTPObservation) -> Self {
        Self(
            id: id,
            status: passed ? "passed" : "failed",
            durationMS: 0,
            httpStatus: response.status,
            errorCode: response.problemCode,
            requestID: response.requestID
        )
    }
}

private enum EvidencePolicy {
    static let iosTests: Set<String> = [
        "physical_device", "identifier_pins", "app_attest_supported", "secure_enclave_key",
        "app_attest_registration", "session_created", "dpop_authorized_request",
        "dpop_replay_rejected", "tampered_dpop_rejected", "streamed_request", "quota",
        "app_attest_assertion",
    ]
}

private struct DeviceObservation: Codable {
    struct Run: Codable {
        let id: String
        let mode: String
        let startedAt: String
        let completedAt: String
        enum CodingKeys: String, CodingKey {
            case id, mode
            case startedAt = "started_at"
            case completedAt = "completed_at"
        }
    }
    struct Application: Codable {
        let identifier: String
        let version: String
        let build: String
        let buildMode: String
        let distribution: String
        let debuggable: Bool
        let signingCertificateSHA256: String
        let teamID: String
        let appAttestEnvironment: String
        enum CodingKeys: String, CodingKey {
            case identifier, version, build, distribution, debuggable
            case buildMode = "build_mode"
            case signingCertificateSHA256 = "signing_certificate_sha256"
            case teamID = "team_id"
            case appAttestEnvironment = "app_attest_environment"
        }
    }
    struct Device: Codable {
        let physical: Bool
        let simulator: Bool
        let emulator: Bool
        let testing: Bool
        let debuggerAttached: Bool
        let model: String
        let osName: String
        let osVersion: String
        let osBuild: String
        let securityLevel: String
        enum CodingKeys: String, CodingKey {
            case physical, simulator, emulator, testing, model
            case debuggerAttached = "debugger_attached"
            case osName = "os_name"
            case osVersion = "os_version"
            case osBuild = "os_build"
            case securityLevel = "security_level"
        }
    }
    struct Provider: Codable {
        let name: String
        let environment: String
        let trustLevel: String
        let requestHashBound: Bool
        let appRecognition: String
        let accountLicensing: String
        enum CodingKeys: String, CodingKey {
            case name, environment
            case trustLevel = "trust_level"
            case requestHashBound = "request_hash_bound"
            case appRecognition = "app_recognition"
            case accountLicensing = "account_licensing"
        }
    }
    struct Redaction: Codable {
        let identityTokenRecorded = false
        let sessionTokenRecorded = false
        let refreshTokenRecorded = false
        let dpopProofRecorded = false
        let attestationEvidenceRecorded = false
        let privateKeyRecorded = false
        let providerCredentialRecorded = false
        enum CodingKeys: String, CodingKey {
            case identityTokenRecorded = "identity_token_recorded"
            case sessionTokenRecorded = "session_token_recorded"
            case refreshTokenRecorded = "refresh_token_recorded"
            case dpopProofRecorded = "dpop_proof_recorded"
            case attestationEvidenceRecorded = "attestation_evidence_recorded"
            case privateKeyRecorded = "private_key_recorded"
            case providerCredentialRecorded = "provider_credential_recorded"
        }
    }

    let schemaVersion: String
    let platform: String
    let run: Run
    let gatewayVersion: String
    let application: Application
    let device: Device
    let provider: Provider
    let observedPins: [String: String]
    let tests: [EvidenceTest]
    let redaction: Redaction

    enum CodingKeys: String, CodingKey {
        case platform, run, application, device, provider, tests, redaction
        case schemaVersion = "schema_version"
        case gatewayVersion = "gateway_version"
        case observedPins = "observed_pins"
    }
}

private enum DeviceFacts {
    #if targetEnvironment(simulator)
    static let physical = false
    static let simulator = true
    #else
    static let physical = true
    static let simulator = false
    #endif

    #if DEBUG
    static let debugBuild = true
    #else
    static let debugBuild = false
    #endif

    static let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    static let debuggerAttached: Bool = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0 else { return true }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }()
    static let model: String = {
        var system = utsname()
        uname(&system)
        return withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }()
    static let osBuild: String = {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 1 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return "unknown" }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }()
}

private enum SuiteError: Error {
    case configuration
    case protocolFailure
}

private struct ConformanceIdentityProvider: LatchwayIdentityTokenProvider {
    let token: String
    func identityToken() async throws -> String { token }
}

private extension Dictionary where Key == String, Value == String {
    func canonical(_ name: String, pattern: String) -> String? {
        guard let value = self[name], value.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return value
    }

    func bounded(_ name: String, maximum: Int) -> String? {
        guard let value = self[name], !value.isEmpty, value.utf8.count <= maximum,
              value.trimmingCharacters(in: .whitespacesAndNewlines) == value,
              value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F })
        else { return nil }
        return value
    }
}

private extension JSONEncoder {
    static var evidence: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
