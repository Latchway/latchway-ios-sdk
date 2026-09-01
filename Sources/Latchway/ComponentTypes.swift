import Foundation

/// A configured execution boundary within one Latchway installation family.
///
/// The access group must be present in both the containing application's and
/// the target extension's signed entitlements. In hardened deployments each
/// component uses a different group, so sibling extensions cannot read one
/// another's key reference or rotating grant.
public struct LatchwayComponentConfiguration: Sendable, Hashable {
    public let definitionID: String
    public let kind: String
    public let keychainAccessGroup: String
    public let requestedFeatures: [String]

    public init(
        definitionID: String,
        kind: String,
        keychainAccessGroup: String,
        requestedFeatures: [String]
    ) {
        self.definitionID = definitionID
        self.kind = kind
        self.keychainAccessGroup = keychainAccessGroup
        self.requestedFeatures = requestedFeatures
    }

    public static func widget(
        definitionID: String,
        keychainAccessGroup: String,
        requestedFeatures: [String]
    ) -> Self {
        .init(
            definitionID: definitionID,
            kind: "widget",
            keychainAccessGroup: keychainAccessGroup,
            requestedFeatures: requestedFeatures
        )
    }

    public static func shareExtension(
        definitionID: String,
        keychainAccessGroup: String,
        requestedFeatures: [String]
    ) -> Self {
        .init(
            definitionID: definitionID,
            kind: "share_extension",
            keychainAccessGroup: keychainAccessGroup,
            requestedFeatures: requestedFeatures
        )
    }

    public static func appIntent(
        definitionID: String,
        keychainAccessGroup: String,
        requestedFeatures: [String]
    ) -> Self {
        .init(
            definitionID: definitionID,
            kind: "app_intent_extension",
            keychainAccessGroup: keychainAccessGroup,
            requestedFeatures: requestedFeatures
        )
    }

    public static func notificationService(
        definitionID: String,
        keychainAccessGroup: String,
        requestedFeatures: [String]
    ) -> Self {
        .init(
            definitionID: definitionID,
            kind: "notification_service_extension",
            keychainAccessGroup: keychainAccessGroup,
            requestedFeatures: requestedFeatures
        )
    }
}

public struct LatchwayInstallationFamilySummary: Sendable, Codable, Equatable {
    public let id: String
    public let status: String

    public init(id: String, status: String) {
        self.id = id
        self.status = status
    }
}

public struct LatchwayClientComponentSummary: Sendable, Codable, Equatable {
    public let id: String
    public let definitionID: String
    public let kind: String
    public let platform: String
    public let isRoot: Bool
    public let dpopJKT: String
    public let status: String
    public let grantedFeatures: [String]

    enum CodingKeys: String, CodingKey {
        case id, kind, platform, status
        case definitionID = "definition_id"
        case isRoot = "is_root"
        case dpopJKT = "dpop_jkt"
        case grantedFeatures = "granted_features"
    }

    public init(
        id: String,
        definitionID: String,
        kind: String,
        platform: String,
        isRoot: Bool,
        dpopJKT: String,
        status: String,
        grantedFeatures: [String]
    ) {
        self.id = id
        self.definitionID = definitionID
        self.kind = kind
        self.platform = platform
        self.isRoot = isRoot
        self.dpopJKT = dpopJKT
        self.status = status
        self.grantedFeatures = grantedFeatures
    }
}

public enum LatchwayComponentTrustSource: String, Sendable, Codable, Equatable {
    case directAttested = "direct_attested"
    case delegatedFromAttestedRoot = "delegated_from_attested_root"
    case delegatedIdentityOnly = "delegated_identity_only"
    case delegatedDirectAttested = "delegated_direct_attested"
    case identityOnly = "identity_only"
    case webRiskVerified = "web_risk_verified"
    case debug
}

public struct LatchwayComponentDiagnostics: Sendable, Equatable {
    public let familyID: String?
    public let componentID: String?
    public let definitionID: String
    public let keychainAccessGroup: String
    public let keyAvailable: Bool
    public let keyStorage: LatchwayKeyStorage
    public let grantAvailable: Bool
    public let sessionAvailable: Bool
    public let trustSource: LatchwayComponentTrustSource?
    public let trustExpiresAt: Date?
    public let containingAppActionRequired: Bool

    public init(
        familyID: String?,
        componentID: String?,
        definitionID: String,
        keychainAccessGroup: String,
        keyAvailable: Bool,
        keyStorage: LatchwayKeyStorage,
        grantAvailable: Bool,
        sessionAvailable: Bool,
        trustSource: LatchwayComponentTrustSource?,
        trustExpiresAt: Date?,
        containingAppActionRequired: Bool
    ) {
        self.familyID = familyID
        self.componentID = componentID
        self.definitionID = definitionID
        self.keychainAccessGroup = keychainAccessGroup
        self.keyAvailable = keyAvailable
        self.keyStorage = keyStorage
        self.grantAvailable = grantAvailable
        self.sessionAvailable = sessionAvailable
        self.trustSource = trustSource
        self.trustExpiresAt = trustExpiresAt
        self.containingAppActionRequired = containingAppActionRequired
    }
}

public struct LatchwayComponentRecovery: Sendable, Equatable {
    public let action: String
    public let openingContainingAppCanFix: Bool
    public let userAuthenticationRequired: Bool
    public let immediateRetryUseful: Bool

    public init(
        action: String,
        openingContainingAppCanFix: Bool,
        userAuthenticationRequired: Bool,
        immediateRetryUseful: Bool
    ) {
        self.action = action
        self.openingContainingAppCanFix = openingContainingAppCanFix
        self.userAuthenticationRequired = userAuthenticationRequired
        self.immediateRetryUseful = immediateRetryUseful
    }
}

public enum LatchwayComponentError: Error, Sendable, Equatable, LocalizedError {
    case containingAppSetupRequired
    case componentNotProvisioned
    case componentGrantExpired
    case componentRevoked
    case installationFamilyRevoked
    case parentTrustExpired
    case featureNotDelegated
    case keychainAccessGroupUnavailable
    case componentKeyUnavailable
    case identityChanged
    case directAttestationRequired
    case invalidConfiguration(String)
    case latchway(LatchwayError)

    public var recovery: LatchwayComponentRecovery {
        switch self {
        case .containingAppSetupRequired, .componentNotProvisioned:
            .init(
                action: "Open the containing app and complete Latchway setup.",
                openingContainingAppCanFix: true,
                userAuthenticationRequired: true,
                immediateRetryUseful: false
            )
        case .componentGrantExpired, .parentTrustExpired:
            .init(
                action: "Open the containing app to renew root trust and provision this component again.",
                openingContainingAppCanFix: true,
                userAuthenticationRequired: true,
                immediateRetryUseful: false
            )
        case .directAttestationRequired:
            .init(
                action: "Complete direct attestation only in a platform extension that supports it; iOS app extensions must remain delegated-only.",
                openingContainingAppCanFix: false,
                userAuthenticationRequired: false,
                immediateRetryUseful: false
            )
        case .componentRevoked, .featureNotDelegated:
            .init(
                action: "Open the containing app and provision the component with an allowed feature scope.",
                openingContainingAppCanFix: true,
                userAuthenticationRequired: false,
                immediateRetryUseful: false
            )
        case .installationFamilyRevoked, .identityChanged:
            .init(
                action: "Open the containing app, authenticate the current user, and create a new installation family.",
                openingContainingAppCanFix: true,
                userAuthenticationRequired: true,
                immediateRetryUseful: false
            )
        case .keychainAccessGroupUnavailable:
            .init(
                action: "Correct the signed Keychain access-group entitlements for both targets, then reinstall the app.",
                openingContainingAppCanFix: false,
                userAuthenticationRequired: false,
                immediateRetryUseful: false
            )
        case .componentKeyUnavailable:
            .init(
                action: "Open the containing app to replace the component key and provision a new grant.",
                openingContainingAppCanFix: true,
                userAuthenticationRequired: false,
                immediateRetryUseful: false
            )
        case .invalidConfiguration:
            .init(
                action: "Correct the component definition, feature scope, or access-group configuration.",
                openingContainingAppCanFix: false,
                userAuthenticationRequired: false,
                immediateRetryUseful: false
            )
        case let .latchway(error):
            .init(
                action: error.localizedDescription,
                openingContainingAppCanFix: false,
                userAuthenticationRequired: false,
                immediateRetryUseful: false
            )
        }
    }

    public var errorDescription: String? { recovery.action }

    /// Stable redaction-safe code for component failures.
    public var code: String {
        switch self {
        case .containingAppSetupRequired: "containing_app_setup_required"
        case .componentNotProvisioned: "component_not_provisioned"
        case .componentGrantExpired: "component_delegation_expired"
        case .componentRevoked: "component_revoked"
        case .installationFamilyRevoked: "installation_family_revoked"
        case .parentTrustExpired: "component_parent_trust_expired"
        case .featureNotDelegated: "component_feature_not_granted"
        case .keychainAccessGroupUnavailable: "keychain_access_group_unavailable"
        case .componentKeyUnavailable: "component_key_invalid"
        case .identityChanged: "identity_reauthentication_required"
        case .directAttestationRequired: "component_direct_attestation_required"
        case .invalidConfiguration: "configuration_invalid"
        case let .latchway(error): error.code
        }
    }

    /// Stable public remediation documentation for ``code``.
    public var documentationURL: URL {
        URL(string: "https://docs.latchway.dev/errors/\(code.replacingOccurrences(of: "_", with: "-"))")!
    }
}

enum LatchwayComponentCredentialKind: String, Sendable, Codable {
    case provisioningGrant = "provisioning_grant"
    case sessionRefreshToken = "session_refresh_token"
}

struct LatchwayStoredComponentCredential: Sendable, Codable, Equatable {
    let family: LatchwayInstallationFamilySummary
    let component: LatchwayClientComponentSummary
    /// The containing application's requested maximum scope. Older stored
    /// credentials decode this as nil and are provisioned again, which avoids
    /// silently retaining a feature removed from configuration.
    let requestedFeatures: [String]?
    let trustSource: LatchwayComponentTrustSource
    let trustExpiresAt: Date
    let keyThumbprint: String
    let rotationToken: String
    let rotationExpiresAt: Date
    let kind: LatchwayComponentCredentialKind

    init(
        family: LatchwayInstallationFamilySummary,
        component: LatchwayClientComponentSummary,
        requestedFeatures: [String]? = nil,
        trustSource: LatchwayComponentTrustSource,
        trustExpiresAt: Date,
        keyThumbprint: String,
        rotationToken: String,
        rotationExpiresAt: Date,
        kind: LatchwayComponentCredentialKind
    ) {
        self.family = family
        self.component = component
        self.requestedFeatures = requestedFeatures
        self.trustSource = trustSource
        self.trustExpiresAt = trustExpiresAt
        self.keyThumbprint = keyThumbprint
        self.rotationToken = rotationToken
        self.rotationExpiresAt = rotationExpiresAt
        self.kind = kind
    }

    func isValid(
        for configuration: LatchwayComponentConfiguration,
        keyThumbprint: String,
        now: Date,
        expectedPlatform: String = "ios",
        rotationLeeway: TimeInterval = 0
    ) -> Bool {
        let features = component.grantedFeatures
        let configuredFeatures = Set(configuration.requestedFeatures)
        return family.id.range(
            of: "^fam_[A-Za-z0-9_-]{16,128}$",
            options: .regularExpression
        ) != nil
            && family.status == "active"
            && component.id.range(
                of: "^cmp_[A-Za-z0-9_-]{16,128}$",
                options: .regularExpression
            ) != nil
            && component.definitionID == configuration.definitionID
            && component.kind == configuration.kind
            && component.platform == expectedPlatform
            && !component.isRoot
            && component.status == "active"
            && self.keyThumbprint == keyThumbprint
            && component.dpopJKT == keyThumbprint
            && keyThumbprint.range(
                of: "^[A-Za-z0-9_-]{43}$",
                options: .regularExpression
            ) != nil
            && requestedFeatures.map(Set.init) == configuredFeatures
            && !features.isEmpty
            && features.count <= 256
            && Set(features).count == features.count
            && Set(features).isSubset(of: configuredFeatures)
            && features.allSatisfy({ feature in
                feature.range(
                    of: "^[a-z][a-z0-9_-]{0,62}$",
                    options: .regularExpression
                ) != nil
            })
            && [
                LatchwayComponentTrustSource.delegatedFromAttestedRoot,
                .delegatedIdentityOnly,
                .delegatedDirectAttested,
            ].contains(trustSource)
            && trustExpiresAt > now
            && rotationExpiresAt.timeIntervalSince(now) > rotationLeeway
            && rotationExpiresAt.timeIntervalSince(now) <= 2_592_300
            && (32 ... 2_048).contains(rotationToken.utf8.count)
            && rotationToken.rangeOfCharacter(
                from: CharacterSet(charactersIn: "\r\n\0")
            ) == nil
    }
}

protocol LatchwayComponentCredentialStorage: Sendable {
    func load() async throws -> LatchwayStoredComponentCredential?
    func save(_ credential: LatchwayStoredComponentCredential) async throws
    func clear() async throws
}
