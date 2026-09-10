import Foundation
import Security

/// Validates and verifies the private Keychain boundary used by Latchway root
/// installation, session, and attestation records.
public enum LatchwayRootKeychainPreflight {
    /// Validates that every group is a fully resolved, concrete Keychain access
    /// group. Build-setting expressions and wildcard groups are rejected.
    public static func validateAccessGroups(
        rootKeychainAccessGroup: String,
        componentKeychainAccessGroups: [String] = []
    ) throws {
        try validateConcreteAccessGroup(
            rootKeychainAccessGroup,
            label: "rootKeychainAccessGroup"
        )

        var seen = Set<String>()
        for group in componentKeychainAccessGroups {
            try validateConcreteAccessGroup(
                group,
                label: "componentKeychainAccessGroups"
            )
            guard group != rootKeychainAccessGroup else {
                throw LatchwayError.invalidConfiguration(
                    "componentKeychainAccessGroups must not contain rootKeychainAccessGroup"
                )
            }
            guard seen.insert(group).inserted else {
                throw LatchwayError.invalidConfiguration(
                    "componentKeychainAccessGroups must not contain duplicates"
                )
            }
        }
    }

    /// Proves that `rootKeychainAccessGroup` is the signed default access group
    /// by creating a random sentinel without an access-group attribute and
    /// reading that sentinel only through the explicit group. The sentinel is
    /// always removed and no Latchway root record is queried without a group.
    public static func verifySignedDefaultAccessGroup(
        _ rootKeychainAccessGroup: String
    ) throws {
        try verify(rootKeychainAccessGroup: rootKeychainAccessGroup, probe: LatchwaySystemRootKeychainProbe())
    }

    static func verifier(rootKeychainAccessGroup: String) -> @Sendable () throws -> Void {
        { try verifySignedDefaultAccessGroup(rootKeychainAccessGroup) }
    }

    static func verify(rootKeychainAccessGroup: String, probe: any LatchwayRootKeychainProbing) throws {
        try validateAccessGroups(rootKeychainAccessGroup: rootKeychainAccessGroup)
        guard try probe.signedDefaultMatches(accessGroup: rootKeychainAccessGroup) else {
            throw LatchwayError.invalidConfiguration(
                "rootKeychainAccessGroup must be the first keychain-access-groups value in the signed application entitlements"
            )
        }
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

protocol LatchwayRootKeychainProbing: Sendable {
    func signedDefaultMatches(accessGroup: String) throws -> Bool
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

    private static func error(for status: OSStatus) -> LatchwayError {
        if status == errSecMissingEntitlement {
            return .invalidConfiguration(
                "a configured Keychain access group is not authorized by the signed application entitlements"
            )
        }
        return .keyStorageFailure
    }
}
