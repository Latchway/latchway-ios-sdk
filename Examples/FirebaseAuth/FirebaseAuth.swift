import FirebaseAuth
import LatchwayFirebaseAuth

let latchwayIdentity = FirebaseLatchwayIdentityTokenProvider {
    guard let user = Auth.auth().currentUser else {
        throw FirebaseIdentityError.signedOut
    }
    return try await user.getIDToken()
}

enum FirebaseIdentityError: Error {
    case signedOut
}
