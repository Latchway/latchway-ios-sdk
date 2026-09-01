import Foundation
import Security

/// Validates and verifies the private Keychain boundary used by Latchway root
/// installation, session, and attestation records.
public enum LatchwayRootKeychainPreflight {
    /// Validates that every group is a fully resolved, concrete Keychain access
    /// group. Build-setting expressions and wildcard groups are rejected.
    public static func validateAccessGroups(
        rootKeychainAccessGroup: String,
        legacySharedKeychainAccessGroups: [String] = []
    ) throws {
        try validateConcreteAccessGroup(
            rootKeychainAccessGroup,
            label: "rootKeychainAccessGroup"
        )

        var seen = Set<String>()
        for group in legacySharedKeychainAccessGroups {
            try validateConcreteAccessGroup(
                group,
                label: "legacySharedKeychainAccessGroups"
            )
            guard group != rootKeychainAccessGroup else {
                throw LatchwayError.invalidConfiguration(
                    "legacySharedKeychainAccessGroups must not contain rootKeychainAccessGroup"
                )
            }
            guard seen.insert(group).inserted else {
                throw LatchwayError.invalidConfiguration(
                    "legacySharedKeychainAccessGroups must not contain duplicates"
                )
            }
        }
    }

    /// Proves that `rootKeychainAccessGroup` is the signed default access group
    /// by creating a random sentinel without an access-group attribute and
    /// reading that sentinel only through the explicit group. The sentinel is
    /// always removed and no Latchway root record is queried without a group.
    public static func verifySignedDefaultAccessGroup(
        _ rootKeychainAccessGroup: String,
        legacySharedKeychainAccessGroups: [String] = []
    ) throws {
        try verify(
            rootKeychainAccessGroup: rootKeychainAccessGroup,
            legacySharedKeychainAccessGroups: legacySharedKeychainAccessGroups,
            legacyRecordCoordinates: [],
            probe: LatchwaySystemRootKeychainProbe()
        )
    }

    static func verifier(
        rootKeychainAccessGroup: String,
        legacySharedKeychainAccessGroups: [String],
        applicationID: String,
        environment: String,
        clientRuntime: LatchwayClientRuntime
    ) -> @Sendable () throws -> Void {
        let records = standardRootRecordCoordinates(
            applicationID: applicationID,
            environment: environment,
            clientRuntime: clientRuntime
        )
        return {
            try verify(
                rootKeychainAccessGroup: rootKeychainAccessGroup,
                legacySharedKeychainAccessGroups: legacySharedKeychainAccessGroups,
                legacyRecordCoordinates: records,
                probe: LatchwaySystemRootKeychainProbe()
            )
        }
    }

    static func verifier(
        rootKeychainAccessGroup: String,
        legacySharedKeychainAccessGroups: [String],
        service: String,
        accounts: [String]
    ) -> @Sendable () throws -> Void {
        let records = accounts.map {
            LatchwayRootKeychainRecordCoordinate(service: service, account: $0)
        }
        return {
            try verify(
                rootKeychainAccessGroup: rootKeychainAccessGroup,
                legacySharedKeychainAccessGroups: legacySharedKeychainAccessGroups,
                legacyRecordCoordinates: records,
                probe: LatchwaySystemRootKeychainProbe()
            )
        }
    }

    static func verify(
        rootKeychainAccessGroup: String,
        legacySharedKeychainAccessGroups: [String],
        legacyRecordCoordinates: [LatchwayRootKeychainRecordCoordinate],
        probe: any LatchwayRootKeychainProbing
    ) throws {
        try validateAccessGroups(
            rootKeychainAccessGroup: rootKeychainAccessGroup,
            legacySharedKeychainAccessGroups: legacySharedKeychainAccessGroups
        )

        let isSignedDefault = try probe.signedDefaultMatches(
            accessGroup: rootKeychainAccessGroup
        )
        let groupsToScan = isSignedDefault
            ? legacySharedKeychainAccessGroups
            : [rootKeychainAccessGroup] + legacySharedKeychainAccessGroups

        for group in groupsToScan {
            for coordinate in legacyRecordCoordinates {
                if try probe.containsRecord(coordinate, accessGroup: group) {
                    throw LatchwayError.rootKeychainMigrationRequired
                }
            }
        }

        guard isSignedDefault else {
            throw LatchwayError.invalidConfiguration(
                "rootKeychainAccessGroup must be the first keychain-access-groups value in the signed application entitlements"
            )
        }
    }

    static func standardRootRecordCoordinates(
        applicationID: String,
        environment: String,
        clientRuntime: LatchwayClientRuntime
    ) -> [LatchwayRootKeychainRecordCoordinate] {
        let rootService = LatchwayKeychainNamespace.service(
            applicationID: applicationID,
            environment: environment,
            clientRuntime: clientRuntime
        )
        let appAttestNamespace = "\(clientRuntime.platformIdentifier).\(applicationID).\(environment)"
        return [
            LatchwayRootKeychainRecordCoordinate(service: rootService, account: "installation-key"),
            LatchwayRootKeychainRecordCoordinate(service: rootService, account: "installation-key-kind"),
            LatchwayRootKeychainRecordCoordinate(service: rootService, account: "session"),
            LatchwayRootKeychainRecordCoordinate(
                service: rootService,
                account: LatchwayKeychainComponentRegistry.account
            ),
            LatchwayRootKeychainRecordCoordinate(
                service: "dev.latchway.sdk.app-attest.\(appAttestNamespace)",
                account: "app-attest-state"
            ),
            LatchwayRootKeychainRecordCoordinate(
                service: "dev.latchway.sdk.app-attest.default",
                account: "app-attest-state"
            ),
        ]
    }

    private static func validateConcreteAccessGroup(
        _ accessGroup: String,
        label: String
    ) throws {
        let byteCount = accessGroup.utf8.count
        let pattern = "\\A[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+\\z"
        guard (3 ... 255).contains(byteCount),
              accessGroup.range(of: pattern, options: .regularExpression) != nil
        else {
            throw LatchwayError.invalidConfiguration(
                "\(label) must contain a fully resolved concrete dotted access group without wildcards or build-setting expressions"
            )
        }
    }
}

struct LatchwayRootKeychainRecordCoordinate: Sendable, Hashable {
    let service: String
    let account: String
}

protocol LatchwayRootKeychainProbing: Sendable {
    func signedDefaultMatches(accessGroup: String) throws -> Bool
    func containsRecord(
        _ coordinate: LatchwayRootKeychainRecordCoordinate,
        accessGroup: String
    ) throws -> Bool
}

private struct LatchwaySystemRootKeychainProbe: LatchwayRootKeychainProbing {
    func signedDefaultMatches(accessGroup: String) throws -> Bool {
        let service = "dev.latchway.sdk.root-keychain-preflight.v1.\(UUID().uuidString)"
        let account = UUID().uuidString
        let sentinel = Data(UUID().uuidString.utf8)
        let insertion: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: sentinel,
        ]
        let addStatus = SecItemAdd(insertion as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw Self.error(for: addStatus)
        }

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessGroup: accessGroup,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: kCFBooleanTrue as Any,
        ]
        var result: CFTypeRef?
        let readStatus = SecItemCopyMatching(query as CFDictionary, &result)

        let deletion: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny,
        ]
        let deleteStatus = SecItemDelete(deletion as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw Self.error(for: deleteStatus)
        }

        if readStatus == errSecItemNotFound { return false }
        guard readStatus == errSecSuccess else { throw Self.error(for: readStatus) }
        guard let data = result as? Data, data == sentinel else {
            throw LatchwayError.keyStorageFailure
        }
        return true
    }

    func containsRecord(
        _ coordinate: LatchwayRootKeychainRecordCoordinate,
        accessGroup: String
    ) throws -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: coordinate.service,
            kSecAttrAccount: coordinate.account,
            kSecAttrAccessGroup: accessGroup,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw Self.error(for: status) }
        return true
    }

    private static func error(for status: OSStatus) -> LatchwayError {
        if status == errSecMissingEntitlement {
            return .invalidConfiguration(
                "a configured Keychain access group is not authorized by the signed application entitlements"
            )
        }
        return .keyStorageFailure
    }
}
