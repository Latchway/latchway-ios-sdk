import Foundation
import Latchway

enum ComponentExampleConfiguration {
    static func latchway(
        attestationProvider: (any LatchwayAttestationProvider)? = nil
    ) throws -> LatchwayConfiguration {
        let gateway = try requiredURL("LatchwayGatewayURL")
        let applicationID = try requiredString("LatchwayApplicationID")
        let environment = try requiredString("LatchwayEnvironment")
        let identityProvider = try requiredString("LatchwayIdentityProvider")
        return LatchwayConfiguration(
            baseURL: gateway,
            applicationID: applicationID,
            environment: environment,
            identityProvider: identityProvider,
            softwareKeyFallbackPolicy: .disallow,
            attestationProvider: attestationProvider
        )
    }

    static func hostDefinitionID() throws -> String {
        try requiredString("LatchwayHostComponentDefinitionID")
    }

    static func widget() throws -> LatchwayComponentConfiguration {
        try component(
            definitionKey: "LatchwayWidgetComponentDefinitionID",
            featureKey: "LatchwayWidgetFeature",
            groupKey: "LatchwayWidgetKeychainAccessGroup",
            kind: "widget"
        )
    }

    static func share() throws -> LatchwayComponentConfiguration {
        try component(
            definitionKey: "LatchwayShareComponentDefinitionID",
            featureKey: "LatchwayShareFeature",
            groupKey: "LatchwayShareKeychainAccessGroup",
            kind: "share_extension"
        )
    }

    static func action() throws -> LatchwayComponentConfiguration {
        try component(
            definitionKey: "LatchwayActionComponentDefinitionID",
            featureKey: "LatchwayActionFeature",
            groupKey: "LatchwayActionKeychainAccessGroup",
            kind: "action_extension"
        )
    }

    static func delegatedComponents() throws -> [LatchwayComponentConfiguration] {
        try [widget(), share(), action()]
    }

    static func feature(for component: LatchwayComponentConfiguration) throws -> String {
        guard let feature = component.requestedFeatures.first,
              component.requestedFeatures.count == 1
        else { throw ExampleConfigurationError.invalidComponentScope }
        return feature
    }

    private static func component(
        definitionKey: String,
        featureKey: String,
        groupKey: String,
        kind: String
    ) throws -> LatchwayComponentConfiguration {
        let accessGroup = try requiredString(groupKey)
        guard !accessGroup.contains("$(") else {
            throw ExampleConfigurationError.unresolvedAccessGroup
        }
        return LatchwayComponentConfiguration(
            definitionID: try requiredString(definitionKey),
            kind: kind,
            keychainAccessGroup: accessGroup,
            requestedFeatures: [try requiredString(featureKey)]
        )
    }

    private static func requiredString(_ key: String) throws -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty
        else { throw ExampleConfigurationError.missing(key) }
        return value
    }

    private static func requiredURL(_ key: String) throws -> URL {
        let value = try requiredString(key)
        guard let url = URL(string: value), url.scheme != nil, url.host != nil else {
            throw ExampleConfigurationError.invalidURL(key)
        }
        return url
    }
}

enum ExampleConfigurationError: Error, LocalizedError {
    case missing(String)
    case invalidURL(String)
    case unresolvedAccessGroup
    case invalidComponentScope

    var errorDescription: String? {
        switch self {
        case let .missing(key): "Missing Info.plist value \(key)."
        case let .invalidURL(key): "Info.plist value \(key) is not an absolute URL."
        case .unresolvedAccessGroup:
            "The runtime Keychain access group still contains an unresolved build-setting token."
        case .invalidComponentScope:
            "The physical component producer requires exactly one configured feature."
        }
    }
}
