import Foundation
import Security

protocol LatchwaySecureDataStoring: Sendable {
    func read(account: String) async throws -> Data?
    func write(_ data: Data, account: String) async throws
    func delete(account: String) async throws
}

actor LatchwayKeychainStore: LatchwaySecureDataStoring {
    private let records: LatchwayKeychainRecords

    init(service: String, accessGroup: String) {
        records = LatchwayKeychainRecords(service: service, accessGroup: accessGroup)
    }

    func read(account: String) throws -> Data? { try records.read(account: account) }
    func write(_ data: Data, account: String) throws { try records.write(data, account: account) }
    func delete(account: String) throws { try records.delete(account: account) }
}

/// Synchronous Security operations allow an owning actor to persist its logout
/// fence and credentials without a suspension point between check and write.
struct LatchwayKeychainRecords: Sendable {
    private let service: String
    private let accessGroup: String

    init(service: String, accessGroup: String) {
        self.service = service
        self.accessGroup = accessGroup
    }

    func read(account: String) throws -> Data? {
        var query = LatchwayKeychainQuery.identity(
            service: service,
            account: account,
            accessGroup: accessGroup,
            synchronizable: kCFBooleanFalse as Any
        )
        query.merge([
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: kCFBooleanTrue as Any,
        ]) { _, new in new }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw LatchwayError.keyStorageFailure }
        return data
    }

    func write(_ data: Data, account: String) throws {
        let identity = LatchwayKeychainQuery.identity(
            service: service,
            account: account,
            accessGroup: accessGroup,
            synchronizable: kCFBooleanFalse as Any
        )
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
        ]
        let update = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw LatchwayError.keyStorageFailure }
        var insertion = identity
        attributes.forEach { insertion[$0.key] = $0.value }
        guard SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess else { throw LatchwayError.keyStorageFailure }
    }

    func delete(account: String) throws {
        let query = LatchwayKeychainQuery.identity(
            service: service,
            account: account,
            accessGroup: accessGroup,
            synchronizable: kSecAttrSynchronizableAny
        )
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LatchwayError.keyStorageFailure }
    }
}

enum LatchwayKeychainQuery {
    static func identity(
        service: String,
        account: String,
        accessGroup: String,
        synchronizable: Any
    ) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessGroup: accessGroup,
            kSecAttrSynchronizable: synchronizable,
        ]
    }
}
