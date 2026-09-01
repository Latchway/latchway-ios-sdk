protocol LatchwayComponentStateRetiring: Sendable {
    func retire(_ component: LatchwayComponentConfiguration) async throws
}

struct LatchwayKeychainComponentStateRetirer: LatchwayComponentStateRetiring {
    let applicationID: String
    let environment: String
    let softwareFallbackPolicy: LatchwaySoftwareKeyFallbackPolicy

    init(configuration: LatchwayConfiguration) {
        applicationID = configuration.applicationID
        environment = configuration.environment
        softwareFallbackPolicy = configuration.softwareKeyFallbackPolicy
    }

    func retire(_ component: LatchwayComponentConfiguration) async throws {
        var cleanupFailed = false
        do {
            try await LatchwayKeychainComponentStorage(
                applicationID: applicationID,
                environment: environment,
                definitionID: component.definitionID,
                accessGroup: component.keychainAccessGroup
            ).clear()
        } catch {
            cleanupFailed = true
        }
        do {
            try await LatchwayComponentKeyManager(
                applicationID: applicationID,
                environment: environment,
                definitionID: component.definitionID,
                keychainAccessGroup: component.keychainAccessGroup,
                softwareFallbackPolicy: softwareFallbackPolicy
            ).reset()
        } catch {
            cleanupFailed = true
        }
        if cleanupFailed {
            throw LatchwayComponentError.keychainAccessGroupUnavailable
        }
    }
}
