@preconcurrency import Foundation
import LatchwayAppExtensions
import Social
import UIKit

@MainActor
final class ComponentShareViewController: SLComposeServiceViewController {
    private var submissionStarted = false

    override func isContentValid() -> Bool { true }

    override func didSelectPost() {
        guard !submissionStarted else { return }
        submissionStarted = true
        Task { await runConformanceRequest() }
    }

    private func runConformanceRequest() async {
        do {
            let configuration = try ComponentExampleConfiguration.latchway()
            let component = try ComponentExampleConfiguration.share()
            let feature = try ComponentExampleConfiguration.feature(for: component)
            let client = try LatchwayExtensionClient(
                configuration: configuration,
                component: component
            )
            let transport = client.transport(feature: feature)
            var request = URLRequest(url: try transport.endpoint(path: "v1/responses"))
            request.httpMethod = "POST"
            request.httpBody = Data(#"{"input":"Return the word conformance.","stream":false}"#.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let response = try await transport.send(request)
            guard (200 ... 299).contains(response.statusCode) else {
                throw ComponentProducerError.gatewayStatus(response.statusCode)
            }
            extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        } catch {
            let safe = (error as? LatchwayComponentError)?.recovery.action
                ?? "Latchway component request failed."
            let alert = UIAlertController(title: "Conformance unavailable", message: safe, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
                self?.extensionContext?.cancelRequest(withError: ComponentProducerError.requestFailed)
            })
            present(alert, animated: true)
        }
    }
}

private enum ComponentProducerError: Error {
    case gatewayStatus(Int)
    case requestFailed
}
