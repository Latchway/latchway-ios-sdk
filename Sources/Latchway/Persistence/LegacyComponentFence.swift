import Foundation

/// A permanent marker in the component's authorized group blocks upgraded
/// legacy extension constructors even when the containing app is not running.
/// Older SDK binaries do not understand this marker and are not a supported
/// downgrade after account-scoped migration.
struct LatchwayLegacyComponentFence: Sendable {
    let records: LatchwayKeychainRecords
    init(configuration: LatchwayConfiguration, component: LatchwayComponentConfiguration) {
        self.init(applicationID: configuration.applicationID, environment: configuration.environment,
                  definitionID: component.definitionID, accessGroup: component.keychainAccessGroup)
    }
    init(applicationID: String, environment: String, definitionID: String, accessGroup: String) {
        records = LatchwayKeychainRecords(service: LatchwayKeychainNamespace.componentService(
            applicationID: applicationID, environment: environment, definitionID: definitionID),
            accessGroup: accessGroup)
    }
    func check() throws {
        if try records.read(account: "shared-native-retirement-v3") != nil {
            throw LatchwayLifecycleError.loggedOut
        }
    }
    func retire() throws {
        try records.write(Data("retired".utf8), account: "shared-native-retirement-v3")
    }
}
