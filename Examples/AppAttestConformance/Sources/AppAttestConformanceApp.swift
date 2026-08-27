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
                        StatusRow(label: "Streamed request", value: model.requestResult)
                        StatusRow(label: "Quota", value: model.quotaResult)
                        StatusRow(label: "Installation", value: model.installationID)
                    }
                    Section {
                        Button(model.running ? "Running…" : "Run conformance") {
                            Task { await model.run(forceFreshChallenge: false) }
                        }
                        .disabled(model.running)
                        Button("Run assertion pass") {
                            Task { await model.run(forceFreshChallenge: true) }
                        }
                        .disabled(model.running)
                    }
                }
                .navigationTitle("Latchway Conformance")
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
    @Published var appAttestKeyID = "none"
    @Published var attestationResult = "not run"
    @Published var sessionResult = "not run"
    @Published var requestResult = "not run"
    @Published var quotaResult = "not run"
    @Published var installationID = "none"
    @Published var running = false

    func run(forceFreshChallenge: Bool) async {
        guard !running else { return }
        running = true
        defer { running = false }

        let environment = ProcessInfo.processInfo.environment
        guard let baseURLText = environment["LATCHWAY_BASE_URL"], let baseURL = URL(string: baseURLText),
              let applicationID = environment["LATCHWAY_APPLICATION_ID"],
              let identityToken = environment["LATCHWAY_IDENTITY_TOKEN"],
              identityToken.utf8.count >= 16
        else {
            identityStatus = "missing Xcode scheme environment"
            return
        }
        identityStatus = "configured"
        let deployment = environment["LATCHWAY_ENVIRONMENT"] ?? "development"
        let feature = environment["LATCHWAY_FEATURE"] ?? "habit-assistant"
        if forceFreshChallenge {
            do {
                try await LatchwayKeychainSessionStorage(
                    applicationID: applicationID,
                    environment: deployment,
                    clientRuntime: .iOS
                ).clear()
            } catch {
                sessionResult = "could not clear stored session"
                return
            }
        }
        let appAttest = LatchwayAppAttestProvider(
            applicationID: applicationID,
            environment: deployment,
            clientRuntime: .iOS
        )
        let configuration = LatchwayConfiguration(
            baseURL: baseURL,
            applicationID: applicationID,
            environment: deployment,
            identityProvider: environment["LATCHWAY_IDENTITY_PROVIDER"] ?? "firebase",
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0",
            softwareKeyFallbackPolicy: .disallow,
            attestationProvider: appAttest
        )
        let client = LatchwayClient(
            configuration: configuration,
            identityTokenProvider: ConformanceIdentityProvider(token: identityToken)
        )

        let initial = await client.diagnostics()
        secureEnclaveStatus = initial.keyStorage == .secureEnclave ? "available" : initial.keyStorage.rawValue
        appAttestSupport = initial.attestation.support.rawValue
        appAttestKeyID = initial.attestation.keyID ?? "none"

        do {
            var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(#"{"stream":true,"messages":[{"role":"user","content":"Reply with the word verified."}]}"#.utf8)
            try await client.authorize(&request, feature: feature)
            let authorized = await client.diagnostics()
            attestationResult = authorized.attestation.lastOperation ?? "accepted"
            sessionResult = authorized.sessionState.rawValue
            installationID = authorized.installationID ?? "unknown"
            appAttestKeyID = authorized.attestation.keyID ?? appAttestKeyID
            secureEnclaveStatus = authorized.keyStorage.rawValue

            let (bytes, response) = try await client.makeURLSession().bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
                throw LatchwayError.invalidServerResponse
            }
            var byteCount = 0
            for try await _ in bytes {
                byteCount += 1
                if byteCount > 1_048_576 { throw LatchwayError.invalidServerResponse }
            }
            requestResult = "passed (\(byteCount) bytes)"

            let snapshot = try await client.quota(feature: feature)
            quotaResult = "passed (\(snapshot.limits.count) limits)"
            let final = await client.diagnostics()
            installationID = final.installationID ?? installationID
        } catch {
            let safe = error as? LatchwayError
            requestResult = safe?.description ?? "failed"
            let diagnostics = await client.diagnostics()
            sessionResult = diagnostics.sessionState.rawValue
            attestationResult = diagnostics.attestation.lastOperation ?? "failed"
            installationID = diagnostics.installationID ?? "none"
        }
    }
}

private struct ConformanceIdentityProvider: LatchwayIdentityTokenProvider {
    let token: String
    func identityToken() async throws -> String { token }
}
