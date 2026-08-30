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
