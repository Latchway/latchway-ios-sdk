import Darwin
import CryptoKit
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
        var environment = ProcessInfo.processInfo.environment
        let registrationIdentityToken = environment.removeValue(
            forKey: "LATCHWAY_REGISTRATION_IDENTITY_TOKEN"
        )
        let assertionIdentityToken = environment.removeValue(
            forKey: "LATCHWAY_ASSERTION_IDENTITY_TOKEN"
        )
        unsetenv("LATCHWAY_REGISTRATION_IDENTITY_TOKEN")
        unsetenv("LATCHWAY_ASSERTION_IDENTITY_TOKEN")
        guard var values = Values(
            environment: environment,
            registrationIdentityToken: registrationIdentityToken,
            assertionIdentityToken: assertionIdentityToken
        ) else {
            identityStatus = "missing or invalid launch configuration"
            return
        }
        identityStatus = "configured"

        do {
            if let checkpoint = try PhysicalComponentProducer.loadCheckpoint(runID: values.runID) {
                guard try PhysicalComponentProducer.observerCompleted(runID: values.runID) else {
                    try PhysicalComponentProducer.ensureReadyMarker(runID: values.runID)
                    identityStatus = "component credentials prepared"
                    evidenceResult = "awaiting independent component observer"
                    return
                }
                await resumeAfterComponentObservation(values: values, checkpoint: checkpoint)
                return
            }
        } catch {
            identityStatus = "invalid component coordination state"
            await writeObservation(values: values, startedAt: startedAt, tests: [], diagnostics: nil)
            return
        }

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

        guard let registrationIdentityProvider = values.takeRegistrationIdentityProvider(),
              let assertionIdentityProvider = values.takeAssertionIdentityProvider()
        else {
            identityStatus = "initial launch requires two distinct one-use grants"
            await writeObservation(values: values, startedAt: startedAt, tests: [], diagnostics: nil)
            return
        }

        let appAttest = LatchwayAppAttestProvider(
            applicationID: values.applicationID,
            environment: values.environment,
            rootKeychainAccessGroup: values.rootKeychainAccessGroup,
            legacySharedKeychainAccessGroups: values.legacySharedKeychainAccessGroups,
            clientRuntime: .iOS
        )
        do {
            guard environment["LATCHWAY_RESET_INSTALLATION"] == "1" else {
                throw SuiteError.configuration
            }
            try await LatchwayKeychainSessionStorage(
                applicationID: values.applicationID,
                environment: values.environment,
                rootKeychainAccessGroup: values.rootKeychainAccessGroup,
                legacySharedKeychainAccessGroups: values.legacySharedKeychainAccessGroups,
                clientRuntime: .iOS
            ).clear()
            try await appAttest.reset()
            try await LatchwayInstallationKeyManager(
                applicationID: values.applicationID,
                environment: values.environment,
                rootKeychainAccessGroup: values.rootKeychainAccessGroup,
                legacySharedKeychainAccessGroups: values.legacySharedKeychainAccessGroups,
                clientRuntime: .iOS,
                softwareFallbackPolicy: .disallow
            ).reset()
        } catch {
            tests.append(.failed(id: "app_attest_registration"))
            attestationResult = "fresh-key reset failed"
            await writeObservation(values: values, startedAt: startedAt, tests: tests, diagnostics: nil)
            return
        }

        let registrationClient = makeClient(
            values: values,
            appAttest: appAttest,
            identityTokenProvider: registrationIdentityProvider
        )
        var diagnostics: LatchwayDiagnostics?
        do {
            let probe = try await authorizedQuotaProbe(client: registrationClient, values: values)
            let first = try await sendBounded(probe, maximumBytes: 65_536)
            tests.append(.http(
                id: "dpop_authorized_request",
                passed: (200 ..< 300).contains(first.status),
                response: first
            ))

            diagnostics = await registrationClient.diagnostics()
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

            // Consume the independently lease-bound assertion grant immediately
            // after registration and the minimum replay check. The extended
            // protocol suite runs only after the assertion session exists, so
            // the second one-use grant is never retained through long tests.
            guard let registeredInstallationID = diagnostics?.installationID,
                  !registeredInstallationID.isEmpty
            else {
                throw SuiteError.protocolFailure
            }
            try await LatchwayKeychainSessionStorage(
                applicationID: values.applicationID,
                environment: values.environment,
                rootKeychainAccessGroup: values.rootKeychainAccessGroup,
                legacySharedKeychainAccessGroups: values.legacySharedKeychainAccessGroups,
                clientRuntime: .iOS
            ).clear()
            let assertionProvider = LatchwayAppAttestProvider(
                applicationID: values.applicationID,
                environment: values.environment,
                rootKeychainAccessGroup: values.rootKeychainAccessGroup,
                legacySharedKeychainAccessGroups: values.legacySharedKeychainAccessGroups,
                clientRuntime: .iOS
            )
            let assertionClient = makeClient(
                values: values,
                appAttest: assertionProvider,
                identityTokenProvider: assertionIdentityProvider
            )
            _ = try await assertionClient.quota(feature: values.feature)
            let assertionDiagnostics = await assertionClient.diagnostics()
            let assertionPassed = assertionDiagnostics.attestation.lastOperation == "assertion"
                && assertionDiagnostics.sessionState == .active
                && assertionDiagnostics.installationID == registeredInstallationID
            tests.append(.boolean(id: "app_attest_assertion", passed: assertionPassed))
            attestationResult = assertionPassed ? "registration + assertion" : "assertion failed"
            diagnostics = assertionDiagnostics

            var tampered = try await authorizedQuotaProbe(client: assertionClient, values: values)
            guard let proof = tampered.value(forHTTPHeaderField: "DPoP"), !proof.isEmpty else {
                throw SuiteError.protocolFailure
            }
            tampered.setValue(try tamperedDPoPProof(proof), forHTTPHeaderField: "DPoP")
            let tamper = try await sendBounded(tampered, maximumBytes: 65_536)
            let tamperPassed = tamper.status == 401 && tamper.problemCode == "dpop_invalid"
            tests.append(.http(id: "tampered_dpop_rejected", passed: tamperPassed, response: tamper))
            tamperResult = tamperPassed ? "passed" : "failed"

            do {
                _ = try await assertionClient.quota(feature: values.errorMappingFeature)
                tests.append(.failed(id: "canonical_error_mapping"))
            } catch let error as LatchwayError {
                if case let .server(problem) = error {
                    tests.append(.mappedError(
                        id: "canonical_error_mapping",
                        problem: problem,
                        expectedCode: .featureNotFound,
                        expectedStatus: 404
                    ))
                } else {
                    tests.append(.failed(id: "canonical_error_mapping"))
                }
            }

            let beforeRefresh = try await authorizedQuotaProbe(client: assertionClient, values: values)
            let beforeRefreshDiagnostics = await assertionClient.diagnostics()
            try await assertionClient.refresh()
            let afterRefresh = try await authorizedQuotaProbe(client: assertionClient, values: values)
            let afterRefreshDiagnostics = await assertionClient.diagnostics()
            tests.append(try .rotation(
                id: "session_refresh_rotation",
                credentialBefore: requiredAuthorizationHash(beforeRefresh),
                credentialAfter: requiredAuthorizationHash(afterRefresh),
                installationBefore: requiredOpaqueHash(beforeRefreshDiagnostics.installationID),
                installationAfter: requiredOpaqueHash(afterRefreshDiagnostics.installationID)
            ))
            diagnostics = afterRefreshDiagnostics

            var unsupportedProtocol = try await authorizedQuotaProbe(client: assertionClient, values: values)
            unsupportedProtocol.setValue("0", forHTTPHeaderField: "X-Latchway-Protocol-Version")
            let unsupported = try await sendBounded(unsupportedProtocol, maximumBytes: 65_536)
            tests.append(.protocolRejection(
                id: "protocol_version_rejection",
                response: unsupported,
                version: 0
            ))

            let stream = try await streamedRequest(client: assertionClient, values: values)
            tests.append(.http(
                id: "streamed_request",
                passed: (200 ..< 300).contains(stream.status) && stream.byteCount > 0,
                response: stream
            ))
            requestResult = (200 ..< 300).contains(stream.status)
                ? "passed (\(stream.byteCount) bytes)"
                : "failed"

            let snapshot = try await assertionClient.quota(feature: values.feature)
            let quotaPassed = snapshot.feature == values.feature && !snapshot.limits.isEmpty
            tests.append(.boolean(id: "quota", passed: quotaPassed))
            quotaResult = quotaPassed ? "passed (\(snapshot.limits.count) limits)" : "failed"

            let completed = Set(tests.filter { $0.status == "passed" }.map(\.id))
            guard EvidencePolicy.preObserverTests.isSubset(of: completed) else {
                throw SuiteError.protocolFailure
            }
            try await PhysicalComponentProducer.stage(
                client: assertionClient,
                runID: values.runID,
                startedAt: startedAt,
                tests: tests
            )
            identityStatus = "component credentials prepared"
            evidenceResult = "awaiting independent component observer"
            return
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
        appAttest: LatchwayAppAttestProvider,
        identityTokenProvider: any LatchwayIdentityTokenProvider
    ) -> LatchwayClient {
        LatchwayClient(
            configuration: LatchwayConfiguration(
                baseURL: values.gateway,
                applicationID: values.applicationID,
                environment: values.environment,
                rootKeychainAccessGroup: values.rootKeychainAccessGroup,
                legacySharedKeychainAccessGroups: values.legacySharedKeychainAccessGroups,
                identityProvider: values.identityProvider,
                appVersion: values.appVersion,
                softwareKeyFallbackPolicy: .disallow,
                attestationProvider: appAttest
            ),
            identityTokenProvider: identityTokenProvider
        )
    }

    private func resumeAfterComponentObservation(
        values: Values,
        checkpoint: PhysicalComponentCheckpoint
    ) async {
        var tests = checkpoint.tests
        let appAttest = LatchwayAppAttestProvider(
            applicationID: values.applicationID,
            environment: values.environment,
            rootKeychainAccessGroup: values.rootKeychainAccessGroup,
            legacySharedKeychainAccessGroups: values.legacySharedKeychainAccessGroups,
            clientRuntime: .iOS
        )
        let client = makeClient(
            values: values,
            appAttest: appAttest,
            identityTokenProvider: UnavailableConformanceIdentityProvider()
        )
        var diagnostics: LatchwayDiagnostics?
        do {
            let postRevocationProbe = try await authorizedQuotaProbe(client: client, values: values)
            let loadedDiagnostics = await client.diagnostics()
            guard loadedDiagnostics.sessionState == .active else {
                throw SuiteError.protocolFailure
            }
            diagnostics = loadedDiagnostics
            try await client.revokeCurrentInstallation()
            let revoked = try await sendBounded(postRevocationProbe, maximumBytes: 65_536)
            tests.append(.http(
                id: "installation_revocation",
                passed: revoked.status == 403 && revoked.problemCode == "installation_revoked",
                response: revoked
            ))
        } catch {
            tests.append(.failed(id: "installation_revocation"))
        }
        await writeObservation(
            values: values,
            startedAt: checkpoint.startedAt,
            tests: tests,
            diagnostics: diagnostics
        )
        try? PhysicalComponentProducer.removeCoordinationFiles()
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
            && trustLevel == "app_verified"
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
    let rootKeychainAccessGroup: String
    let legacySharedKeychainAccessGroups: [String]
    private var registrationIdentityToken: String?
    private var assertionIdentityToken: String?
    let feature: String
    let errorMappingFeature: String
    let model: String
    let runID: String
    let distribution: String
    let appVersion: String
    let buildNumber: String
    let teamID: String
    let signingCertificateSHA256: String
    let appAttestEnvironment: String
    let observedPins: [String: String]

    init?(
        environment values: [String: String],
        registrationIdentityToken: String?,
        assertionIdentityToken: String?
    ) {
        guard let gatewayText = values["LATCHWAY_BASE_URL"],
              let gateway = URL(string: gatewayText), gateway.scheme == "https", gateway.host != nil,
              let gatewayOrigin = values.bounded("LATCHWAY_GATEWAY_ORIGIN", maximum: 512),
              gatewayText == gatewayOrigin,
              let applicationID = values.canonical(
                  "LATCHWAY_APPLICATION_ID",
                  pattern: "^app_[0-7][0-9A-HJKMNP-TV-Z]{25}$"
              ),
              let environment = values.canonical("LATCHWAY_ENVIRONMENT", pattern: "^[a-z][a-z0-9_-]{0,62}$"),
              let identityProvider = values.canonical(
                  "LATCHWAY_IDENTITY_PROVIDER",
                  pattern: "^[a-z][a-z0-9_-]{0,62}$"
              ),
              let feature = values.canonical("LATCHWAY_FEATURE", pattern: "^[a-z][a-z0-9_-]{0,62}$"),
              let errorMappingFeature = values.canonical(
                  "LATCHWAY_ERROR_MAPPING_FEATURE",
                  pattern: "^[a-z][a-z0-9_-]{0,62}$"
              ),
              errorMappingFeature != feature,
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
              let signedApplicationID = Bundle.main.object(
                  forInfoDictionaryKey: "LatchwayApplicationID"
              ) as? String,
              let signedEnvironment = Bundle.main.object(
                  forInfoDictionaryKey: "LatchwayEnvironment"
              ) as? String,
              let signedIdentityProvider = Bundle.main.object(
                  forInfoDictionaryKey: "LatchwayIdentityProvider"
              ) as? String,
              let rootKeychainAccessGroup = Bundle.main.object(
                  forInfoDictionaryKey: "LatchwayRootKeychainAccessGroup"
              ) as? String,
              let widgetKeychainAccessGroup = Bundle.main.object(
                  forInfoDictionaryKey: "LatchwayWidgetKeychainAccessGroup"
              ) as? String,
              let shareKeychainAccessGroup = Bundle.main.object(
                  forInfoDictionaryKey: "LatchwayShareKeychainAccessGroup"
              ) as? String,
              let actionKeychainAccessGroup = Bundle.main.object(
                  forInfoDictionaryKey: "LatchwayActionKeychainAccessGroup"
              ) as? String,
              applicationID == signedApplicationID,
              environment == signedEnvironment,
              identityProvider == signedIdentityProvider,
              let identifier = Bundle.main.bundleIdentifier
        else { return nil }
        let legacySharedKeychainAccessGroups = [
            widgetKeychainAccessGroup,
            shareKeychainAccessGroup,
            actionKeychainAccessGroup,
        ]
        guard rootKeychainAccessGroup.range(
            of: "^[A-Za-z0-9][A-Za-z0-9.-]{2,254}$",
            options: .regularExpression
        ) != nil,
        !rootKeychainAccessGroup.contains("$("),
        legacySharedKeychainAccessGroups.allSatisfy({
            !$0.contains("$(") && $0.range(
                of: "^[A-Za-z0-9][A-Za-z0-9.-]{2,254}$",
                options: .regularExpression
            ) != nil
        }),
        !legacySharedKeychainAccessGroups.contains(rootKeychainAccessGroup),
        Set(legacySharedKeychainAccessGroups).count == legacySharedKeychainAccessGroups.count
        else { return nil }
        self.gateway = gateway
        self.applicationID = signedApplicationID
        self.environment = signedEnvironment
        self.identityProvider = signedIdentityProvider
        self.rootKeychainAccessGroup = rootKeychainAccessGroup
        self.legacySharedKeychainAccessGroups = legacySharedKeychainAccessGroups
        let grantsAbsent = registrationIdentityToken == nil && assertionIdentityToken == nil
        let grantsValid = registrationIdentityToken.map { (16 ... 65_536).contains($0.utf8.count) } == true
            && assertionIdentityToken.map { (16 ... 65_536).contains($0.utf8.count) } == true
            && registrationIdentityToken != assertionIdentityToken
        let grantlessResumeIsValid: Bool
        if grantsAbsent {
            do {
                grantlessResumeIsValid = try PhysicalComponentProducer.loadCheckpoint(runID: runID) != nil
                    && PhysicalComponentProducer.observerCompleted(runID: runID)
            } catch {
                return nil
            }
        } else {
            grantlessResumeIsValid = false
        }
        guard grantsValid || grantlessResumeIsValid else { return nil }
        self.registrationIdentityToken = registrationIdentityToken
        self.assertionIdentityToken = assertionIdentityToken
        self.feature = feature
        self.errorMappingFeature = errorMappingFeature
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
            "latchway_application_id": signedApplicationID,
            "latchway_environment": signedEnvironment,
            "identity_provider": signedIdentityProvider,
            "root_keychain_access_group": rootKeychainAccessGroup,
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
            "error_mapping_feature": errorMappingFeature,
        ]
    }

    mutating func takeRegistrationIdentityProvider() -> SingleUseConformanceIdentityProvider? {
        guard let token = registrationIdentityToken else { return nil }
        registrationIdentityToken = nil
        return SingleUseConformanceIdentityProvider(token: token)
    }

    mutating func takeAssertionIdentityProvider() -> SingleUseConformanceIdentityProvider? {
        guard let token = assertionIdentityToken else { return nil }
        assertionIdentityToken = nil
        return SingleUseConformanceIdentityProvider(token: token)
    }

    var localPinsMatch: Bool {
        observedPins["application_identifier"] == Bundle.main.bundleIdentifier
            && observedPins["latchway_application_id"] == applicationID
            && observedPins["latchway_environment"] == environment
            && observedPins["identity_provider"] == identityProvider
            && observedPins["root_keychain_access_group"] == rootKeychainAccessGroup
            && observedPins["app_version"] == appVersion
            && observedPins["build_number"] == buildNumber
            && appAttestEnvironment == "production"
    }
}

struct HTTPObservation {
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
    let documentationURL = object?["documentation_url"] as? String
    let bodyRequestID = object?["request_id"] as? String
    let headerRequestID = http.value(forHTTPHeaderField: "X-Latchway-Request-ID")
    let validProblem = bodyStatus == http.statusCode
        && bodyRequestID == headerRequestID
        && type == code.map { "https://docs.latchway.dev/errors/\($0.replacingOccurrences(of: "_", with: "-"))" }
        && documentationURL == type
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

struct EvidenceTest: Codable {
    let id: String
    let status: String
    let durationMS: Int
    let httpStatus: Int?
    let errorCode: String?
    let requestID: String?
    let mappedErrorType: String?
    let credentialBeforeSHA256: String?
    let credentialAfterSHA256: String?
    let installationBeforeSHA256: String?
    let installationAfterSHA256: String?
    let protocolVersionSent: Int?

    enum CodingKeys: String, CodingKey {
        case id, status
        case durationMS = "duration_ms"
        case httpStatus = "http_status"
        case errorCode = "error_code"
        case requestID = "request_id"
        case mappedErrorType = "mapped_error_type"
        case credentialBeforeSHA256 = "credential_before_sha256"
        case credentialAfterSHA256 = "credential_after_sha256"
        case installationBeforeSHA256 = "installation_before_sha256"
        case installationAfterSHA256 = "installation_after_sha256"
        case protocolVersionSent = "protocol_version_sent"
    }

    init(
        id: String,
        status: String,
        durationMS: Int = 0,
        httpStatus: Int? = nil,
        errorCode: String? = nil,
        requestID: String? = nil,
        mappedErrorType: String? = nil,
        credentialBeforeSHA256: String? = nil,
        credentialAfterSHA256: String? = nil,
        installationBeforeSHA256: String? = nil,
        installationAfterSHA256: String? = nil,
        protocolVersionSent: Int? = nil
    ) {
        self.id = id
        self.status = status
        self.durationMS = durationMS
        self.httpStatus = httpStatus
        self.errorCode = errorCode
        self.requestID = requestID
        self.mappedErrorType = mappedErrorType
        self.credentialBeforeSHA256 = credentialBeforeSHA256
        self.credentialAfterSHA256 = credentialAfterSHA256
        self.installationBeforeSHA256 = installationBeforeSHA256
        self.installationAfterSHA256 = installationAfterSHA256
        self.protocolVersionSent = protocolVersionSent
    }

    static func boolean(id: String, passed: Bool) -> Self {
        Self(id: id, status: passed ? "passed" : "failed")
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

    static func mappedError(
        id: String,
        problem: LatchwayProblem,
        expectedCode: LatchwayErrorCode,
        expectedStatus: Int
    ) -> Self {
        Self(
            id: id,
            status: problem.code == expectedCode && problem.status == expectedStatus ? "passed" : "failed",
            httpStatus: problem.status,
            errorCode: problem.code.description,
            requestID: problem.requestID,
            mappedErrorType: "swift_latchway_problem"
        )
    }

    static func rotation(
        id: String,
        credentialBefore: String,
        credentialAfter: String,
        installationBefore: String,
        installationAfter: String
    ) throws -> Self {
        Self(
            id: id,
            status: credentialBefore != credentialAfter && installationBefore == installationAfter
                ? "passed" : "failed",
            credentialBeforeSHA256: credentialBefore,
            credentialAfterSHA256: credentialAfter,
            installationBeforeSHA256: installationBefore,
            installationAfterSHA256: installationAfter
        )
    }

    static func protocolRejection(id: String, response: HTTPObservation, version: Int) -> Self {
        Self(
            id: id,
            status: response.status == 426 && response.problemCode == "protocol_version_unsupported"
                ? "passed" : "failed",
            httpStatus: response.status,
            errorCode: response.problemCode,
            requestID: response.requestID,
            protocolVersionSent: version
        )
    }
}

enum EvidencePolicy {
    static let iosTests: Set<String> = [
        "physical_device", "identifier_pins", "app_attest_supported", "secure_enclave_key",
        "app_attest_registration", "session_created", "dpop_authorized_request",
        "dpop_replay_rejected", "tampered_dpop_rejected", "streamed_request", "quota",
        "app_attest_assertion", "canonical_error_mapping", "session_refresh_rotation",
        "installation_revocation", "protocol_version_rejection",
    ]

    static let preObserverTests = iosTests.subtracting(["installation_revocation"])
}

private func requiredAuthorizationHash(_ request: URLRequest) throws -> String {
    guard let value = request.value(forHTTPHeaderField: "Authorization"),
          value.hasPrefix("DPoP "), value.utf8.count >= 37
    else { throw SuiteError.protocolFailure }
    return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func requiredOpaqueHash(_ value: String?) throws -> String {
    guard let value, !value.isEmpty else { throw SuiteError.protocolFailure }
    return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
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
    case identityUnavailable
    case protocolFailure
}

private actor SingleUseConformanceIdentityProvider: LatchwayIdentityTokenProvider {
    private var token: String?

    init(token: String) { self.token = token }

    func identityToken() async throws -> String {
        guard let token else { throw SuiteError.identityUnavailable }
        self.token = nil
        return token
    }
}

private struct UnavailableConformanceIdentityProvider: LatchwayIdentityTokenProvider {
    func identityToken() async throws -> String { throw SuiteError.identityUnavailable }
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
