import Latchway
import LatchwayAppAttest
import LatchwayAppExtensions
import LatchwayFirebaseAuth
import LatchwayFoundationModels
import LatchwaySwiftOpenAI
import LatchwayTesting

let concreteAPIs = [
    String(reflecting: LatchwayVersion.self),
    String(reflecting: LatchwayAppAttestProvider.self),
    String(reflecting: FirebaseLatchwayIdentityTokenProvider.self),
    String(reflecting: LatchwaySwiftOpenAIHTTPClient.self),
    String(reflecting: LatchwayInMemorySessionStorage.self),
]
let importedPublicProducts = 7

guard concreteAPIs.count == 5,
      importedPublicProducts == 7,
      !LatchwayVersion.sdk.isEmpty
else {
    fatalError("Latchway package products were not available to a clean consumer")
}

print("Latchway consumer smoke: \(LatchwayVersion.sdk)")

// Existing exhaustive SwiftPM switches must remain source-compatible in patches.
func existingCoreErrorSwitch(_ error: LatchwayError) -> String {
    switch error {
    case .invalidConfiguration: "configuration"
    case .invalidRequest: "request"
    case .secureEnclaveUnavailable: "enclave"
    case .keyStorageFailure: "storage"
    case .attestationUnavailable: "attestation"
    case .invalidAttestationBinding: "binding"
    case .sessionUnavailable: "session"
    case .transportFailure: "transport"
    case .invalidServerResponse: "response"
    case .server: "server"
    case .cancelled: "cancelled"
    }
}

#if canImport(FoundationModels) && compiler(>=6.4)
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
@available(tvOS, unavailable)
func existingFoundationModelsErrorSwitch(_ error: LatchwayFoundationModelsError) -> String {
    switch error {
    case .invalidTranscript: "transcript"
    case .unsupportedSamplingMode: "sampling"
    case .gateway: "gateway"
    case .invalidGatewayStream: "stream"
    }
}
#endif
