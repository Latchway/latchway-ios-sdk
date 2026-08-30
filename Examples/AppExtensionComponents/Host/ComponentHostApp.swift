import Foundation
import Latchway
import LatchwayAppAttest
import SwiftUI

@main
struct ComponentHostApp: App {
    @StateObject private var model = ComponentHostModel()

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 16) {
                Text("Latchway component boundary")
                    .font(.headline)
                Text(model.status)
                    .multilineTextAlignment(.center)
                Button("Prepare widget") {
                    Task { await model.prepareWidget() }
                }
                Button("Replace widget key") {
                    Task { await model.replaceWidget() }
                }
                Button("Revoke family and erase keys", role: .destructive) {
                    Task { await model.revokeFamily() }
                }
            }
            .padding()
        }
    }
}

@MainActor
private final class ComponentHostModel: ObservableObject {
    @Published var status = "The containing app has not provisioned the widget."
    private var client: LatchwayClient?

    func prepareWidget() async {
        do {
            let client = try makeClient()
            let component = try ComponentExampleConfiguration.widget()
            let result = try await client.prepareComponents([component])
            let prepared = result.first?.containingAppActionRequired == false
            status = prepared ? "Widget key and one-time grant are prepared." : "Preparation needs attention."
            self.client = client
        } catch {
            status = safeDescription(error)
        }
    }

    func replaceWidget() async {
        do {
            let client = try makeClient()
            let component = try ComponentExampleConfiguration.widget()
            _ = try await client.replaceComponent(component)
            status = "The old component session is revoked and a new key is prepared."
            self.client = client
        } catch {
            status = safeDescription(error)
        }
    }

    func revokeFamily() async {
        do {
            let client = try client ?? makeClient()
            let component = try ComponentExampleConfiguration.widget()
            try await client.revokeCurrentInstallationFamily(retiring: [component])
            status = "The family is revoked and root/component Keychain material was erased."
            self.client = nil
        } catch {
            status = safeDescription(error)
        }
    }

    private func makeClient() throws -> LatchwayClient {
        let applicationID = try requiredInfo("LatchwayApplicationID")
        let environment = try requiredInfo("LatchwayEnvironment")
        let attestation = LatchwayAppAttestProvider(
            applicationID: applicationID,
            environment: environment,
            rootKeychainAccessGroup: try ComponentExampleConfiguration.rootKeychainAccessGroup(),
            legacySharedKeychainAccessGroups: ComponentExampleConfiguration.legacySharedKeychainAccessGroups()
        )
        return LatchwayClient(
            configuration: try ComponentExampleConfiguration.latchway(
                attestationProvider: attestation
            ),
            identityTokenProvider: LaunchEnvironmentIdentityProvider()
        )
    }

    private func requiredInfo(_ key: String) throws -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty
        else { throw ExampleConfigurationError.missing(key) }
        return value
    }

    private func safeDescription(_ error: Error) -> String {
        if let component = error as? LatchwayComponentError {
            return component.recovery.action
        }
        return (error as? LocalizedError)?.errorDescription ?? "Latchway setup failed."
    }
}

private struct LaunchEnvironmentIdentityProvider: LatchwayIdentityTokenProvider {
    func identityToken() async throws -> String {
        guard let token = ProcessInfo.processInfo.environment["LATCHWAY_IDENTITY_TOKEN"],
              (16 ... 65_536).contains(token.utf8.count)
        else { throw HostIdentityError.missingIdentityToken }
        return token
    }
}

private enum HostIdentityError: Error, LocalizedError {
    case missingIdentityToken

    var errorDescription: String? {
        "Provide LATCHWAY_IDENTITY_TOKEN in the host app's launch environment."
    }
}
