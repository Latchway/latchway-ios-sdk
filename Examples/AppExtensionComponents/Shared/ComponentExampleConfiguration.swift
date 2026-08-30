import Foundation
import Latchway

enum ComponentExampleConfiguration {
    static func latchway(
        attestationProvider: (any LatchwayAttestationProvider)? = nil
    ) throws -> LatchwayConfiguration {
        let gateway = try requiredURL("LatchwayGatewayURL")
        let applicationID = try requiredString("LatchwayApplicationID")
        let environment = try requiredString("LatchwayEnvironment")
        return LatchwayConfiguration(
            baseURL: gateway,
            applicationID: applicationID,
            environment: environment,
            softwareKeyFallbackPolicy: .disallow,
            attestationProvider: attestationProvider
        )
    }

    static func widget() throws -> LatchwayComponentConfiguration {
        let accessGroup = try requiredString("LatchwayComponentKeychainAccessGroup")
        guard !accessGroup.contains("$(") else {
            throw ExampleConfigurationError.unresolvedAccessGroup
        }
        return .widget(
            definitionID: "home_widget",
            keychainAccessGroup: accessGroup,
            requestedFeatures: ["weekly-summary"]
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
    case missingIdentityToken

    var errorDescription: String? {
        switch self {
        case let .missing(key): "Missing Info.plist value \(key)."
        case let .invalidURL(key): "Info.plist value \(key) is not an absolute URL."
        case .unresolvedAccessGroup:
            "The runtime Keychain access group still contains an unresolved build-setting token."
        case .missingIdentityToken:
            "Provide LATCHWAY_IDENTITY_TOKEN in the host app's launch environment."
        }
    }
}

struct LaunchEnvironmentIdentityProvider: LatchwayIdentityTokenProvider {
    func identityToken() async throws -> String {
        guard let token = ProcessInfo.processInfo.environment["LATCHWAY_IDENTITY_TOKEN"],
              (16 ... 65_536).contains(token.utf8.count)
        else { throw ExampleConfigurationError.missingIdentityToken }
        return token
    }
}
