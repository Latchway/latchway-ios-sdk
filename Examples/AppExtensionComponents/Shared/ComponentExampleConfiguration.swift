import Foundation
import Latchway
import Security

enum ComponentExampleConfiguration {
    static func latchway(
        attestationProvider: (any LatchwayAttestationProvider)? = nil
    ) throws -> LatchwayConfiguration {
        let gateway = try requiredURL("LatchwayGatewayURL")
        let applicationID = try requiredString("LatchwayApplicationID")
        let environment = try requiredString("LatchwayEnvironment")
        let identityProvider = try requiredString("LatchwayIdentityProvider")
        let rootKeychainAccessGroup = try requiredString("LatchwayRootKeychainAccessGroup")
        return LatchwayConfiguration(
            baseURL: gateway,
            applicationID: applicationID,
            environment: environment,
            rootKeychainAccessGroup: rootKeychainAccessGroup,
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

    static func rootKeychainAccessGroup() throws -> String {
        try requiredString("LatchwayRootKeychainAccessGroup")
    }

    static func componentKeychainAccessGroups() -> [String] {
        [
            optionalString("LatchwayWidgetKeychainAccessGroup"),
            optionalString("LatchwayShareKeychainAccessGroup"),
            optionalString("LatchwayActionKeychainAccessGroup"),
        ].compactMap { $0 }
    }

    static func firebaseProjectID() throws -> String {
        try requiredString("LatchwayFirebaseProjectID")
    }

    /// Application-owned handoff metadata, never a root credential. Each
    /// extension reads only its exact signed group; the SDK checks the live
    /// account generation and component retirement record before every request.
    static func saveAccount(_ account: LatchwayComponentAccount,
                            for component: LatchwayComponentConfiguration) throws {
        let query = try handoffQuery(component)
        let data = try JSONEncoder().encode(account)
        let status = SecItemUpdate(query as CFDictionary,
                                   [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insertion = query
            insertion[kSecValueData] = data
            insertion[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess else {
                throw ExampleConfigurationError.accountHandoffUnavailable
            }
        } else if status != errSecSuccess {
            throw ExampleConfigurationError.accountHandoffUnavailable
        }
    }

    static func account(for component: LatchwayComponentConfiguration) throws -> LatchwayComponentAccount {
        var query = try handoffQuery(component)
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecReturnData] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count <= 4096 else {
            throw ExampleConfigurationError.accountHandoffUnavailable
        }
        return try JSONDecoder().decode(LatchwayComponentAccount.self, from: data)
    }

    private static func handoffQuery(_ component: LatchwayComponentConfiguration) throws -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword,
         kSecAttrService: "dev.latchway.example.account-handoff",
         kSecAttrAccount: try requiredString("LatchwayApplicationID") + "." +
            requiredString("LatchwayEnvironment") + "." + component.definitionID,
         kSecAttrAccessGroup: component.keychainAccessGroup,
         kSecAttrSynchronizable: kCFBooleanFalse as Any,
         kSecUseDataProtectionKeychain: true]
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

    private static func optionalString(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty
        else { return nil }
        return value
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
    case accountHandoffUnavailable

    var errorDescription: String? {
        switch self {
        case let .missing(key): "Missing Info.plist value \(key)."
        case let .invalidURL(key): "Info.plist value \(key) is not an absolute URL."
        case .unresolvedAccessGroup:
            "The runtime Keychain access group still contains an unresolved build-setting token."
        case .invalidComponentScope:
            "The physical component producer requires exactly one configured feature."
        case .accountHandoffUnavailable:
            "Open the containing app to prepare this account's extension handoff."
        }
    }
}
