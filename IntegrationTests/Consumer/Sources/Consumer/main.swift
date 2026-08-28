import Latchway
import LatchwayAppAttest
import LatchwayFirebaseAuth
import LatchwayTesting

let products = [
    String(reflecting: LatchwayVersion.self),
    String(reflecting: LatchwayAppAttestProvider.self),
    String(reflecting: FirebaseLatchwayIdentityTokenProvider.self),
    String(reflecting: LatchwayInMemorySessionStorage.self),
]

guard products.count == 4, !LatchwayVersion.sdk.isEmpty else {
    fatalError("Latchway package products were not available to a clean consumer")
}

print("Latchway consumer smoke: \(LatchwayVersion.sdk)")
