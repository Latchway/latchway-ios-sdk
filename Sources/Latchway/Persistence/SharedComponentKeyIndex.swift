import Foundation

/// Root-private, non-secret inventory used by the existing eight-account key
/// retention policy. It is written before initializing any component key state.
/// The root journal serializes registration; eviction runs only before another
/// account activates, after the previous generation's cleanup is complete.
struct LatchwaySharedComponentKeyIndex: Sendable {
    struct Entry: Codable {
        let account: LatchwayComponentAccount
        let component: LatchwayComponentConfiguration
    }
    let records: any LatchwayLifecycleRecords
    private let componentState: @Sendable (LatchwayComponentAccount, LatchwayComponentConfiguration) -> LatchwaySharedComponentState
    private static let name = "component-key-index-v3"

    init(records: LatchwayKeychainRecords) {
        self.records = IndexRecords(records: records)
        componentState = { LatchwaySharedComponentState(account: $0, component: $1) }
    }

    init(records: any LatchwayLifecycleRecords,
         componentState: @escaping @Sendable (LatchwayComponentAccount, LatchwayComponentConfiguration) -> LatchwaySharedComponentState) {
        self.records = records
        self.componentState = componentState
    }

    private struct IndexRecords: LatchwayLifecycleRecords {
        let records: LatchwayKeychainRecords
        func read() throws -> Data? { try records.read(account: LatchwaySharedComponentKeyIndex.name) }
        func write(_ data: Data) throws { try records.write(data, account: LatchwaySharedComponentKeyIndex.name) }
    }

    private func load() throws -> [Entry] {
        guard let data = try records.read() else { return [] }
        guard data.count <= 1_048_576, (try? StrictJSON.validate(data)) != nil,
              let entries = try? JSONDecoder().decode([Entry].self, from: data), entries.count <= 2_048
        else { throw LatchwayLifecycleError.cleanupRequired }
        var coordinates = Set<String>()
        for entry in entries {
            try entry.component.validateForContainingApplication()
            guard entry.account.accountScope.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  entry.account.appScope.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  coordinates.insert(entry.account.service(entry.component) + "|" + entry.component.keychainAccessGroup).inserted
            else { throw LatchwayLifecycleError.cleanupRequired }
        }
        return entries
    }

    func register(account: LatchwayComponentAccount, component: LatchwayComponentConfiguration) throws {
        var entries = try load()
        entries.removeAll { $0.account.service($0.component) == account.service(component)
            && $0.component.keychainAccessGroup == component.keychainAccessGroup }
        entries.append(.init(account: account, component: component))
        guard entries.count <= 2_048 else { throw LatchwayLifecycleError.cleanupRequired }
        let data = try JSONEncoder().encode(entries)
        guard data.count <= 1_048_576 else { throw LatchwayLifecycleError.cleanupRequired }
        try records.write(data)
    }

    func evict(accountScope: String) throws {
        let entries = try load()
        for entry in entries where entry.account.accountScope == accountScope {
            try componentState(entry.account, entry.component).evictRetiredKeys()
        }
        // Partial erasure leaves the inventory intact for the retention
        // journal's retry. Tombstones remain so stale handles never reopen.
        let remaining = entries.filter { $0.account.accountScope != accountScope }
        try records.write(JSONEncoder().encode(remaining))
    }
}
