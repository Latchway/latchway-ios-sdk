@preconcurrency import Foundation
import Latchway
import LatchwayAppExtensions
import UIKit

@MainActor
final class ComponentActionViewController: UIViewController {
    private let statusLabel = UILabel()
    private var operationStarted = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        statusLabel.accessibilityIdentifier = "latchway-action-delegated-status"
        statusLabel.numberOfLines = 0
        statusLabel.text = "Awaiting delegated component request"
        statusLabel.textAlignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !operationStarted else { return }
        operationStarted = true
        Task { await performDelegatedRequest() }
    }

    private func performDelegatedRequest() async {
        do {
            let configuration = try ComponentExampleConfiguration.latchway()
            let component = try ComponentExampleConfiguration.action()
            let feature = try ComponentExampleConfiguration.feature(for: component)
            let client = try LatchwayExtensionClient(
                configuration: configuration,
                component: component
            )

            // iOS App Attest key generation is unavailable to application
            // extensions. The containing app provisions only a component DPoP
            // key and one-time delegated grant; this process consumes its own
            // grant/session and never receives an App Attest provider.
            try await client.refresh()
            let diagnostics = await client.diagnostics()
            guard diagnostics.trustSource == .delegatedFromAttestedRoot,
                  diagnostics.keyAvailable,
                  diagnostics.keyStorage == .secureEnclave,
                  diagnostics.sessionAvailable
            else { throw ComponentProducerError.delegatedTrustUnavailable }

            let transport = client.transport(feature: feature)
            var request = URLRequest(url: try transport.endpoint(path: "v1/responses"))
            request.httpMethod = "POST"
            request.httpBody = Data(#"{"input":"Return the word conformance.","stream":false}"#.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let response = try await transport.send(request)
            guard (200 ... 299).contains(response.statusCode) else {
                throw ComponentProducerError.gatewayStatus(response.statusCode)
            }
            statusLabel.text = "Delegated component request complete"
            statusLabel.accessibilityValue = "delegated_from_attested_root"
        } catch {
            statusLabel.text = (error as? LatchwayComponentError)?.recovery.action
                ?? "Delegated component request failed"
            statusLabel.accessibilityValue = "failed"
        }
    }
}

private enum ComponentProducerError: Error {
    case delegatedTrustUnavailable
    case gatewayStatus(Int)
}
