import Foundation

struct LatchwaySuppliedIdentityDiscovery: Decodable {
    let capabilities: [String]?
    let identityVerificationEndpoint: String?
    enum CodingKeys: String, CodingKey {
        case capabilities
        case identityVerificationEndpoint = "identity_verification_endpoint"
    }
}

struct LatchwayIdentityVerificationRequest: Encodable {
    struct Identity: Encodable { let provider: String; let token: String }
    let refreshToken: String
    let identity: Identity
    enum CodingKeys: String, CodingKey { case refreshToken = "refresh_token", identity }
}

struct LatchwayVerifiedIdentityWire: Decodable, Sendable {
    struct Identity: Decodable, Sendable {
        let provider: String
        let issuer: String
        let subject: String
        let audience: [String]
        let verifiedAt: Date
        let expiresAt: Date
        enum CodingKeys: String, CodingKey {
            case provider, issuer, subject, audience
            case verifiedAt = "verified_at", expiresAt = "expires_at"
        }
    }
    let identity: Identity
    let installationID: String
    enum CodingKeys: String, CodingKey { case identity, installationID = "installation_id" }
}
