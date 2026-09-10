import Foundation

/// Keeps at most eight inactive/current account key scopes. An eviction intent
/// is committed before keys are erased and retried after interruption. It never
/// contains user IDs or credentials; every entry is an account-scoped namespace.
actor LatchwayAccountKeyRetention {
    private struct Index: Codable {
        var version = 1
        var retained: [String] = []
        var evicting: [String] = []
    }
    private let records: any LatchwayLifecycleRecords
    private let limit: Int
    private let evict: @Sendable (String) async throws -> Void

    init(records: any LatchwayLifecycleRecords, limit: Int = 8,
         evict: @escaping @Sendable (String) async throws -> Void) {
        precondition((1 ... 32).contains(limit))
        self.records = records
        self.limit = limit
        self.evict = evict
    }

    /// Called by the app's single-flight activation after checking that no
    /// different account is active, and before publishing the new generation.
    func prepare(_ scope: String) async throws {
        do {
            let encoded = try records.read()
            guard (encoded?.count ?? 0) <= 16_384 else { throw LatchwayLifecycleError.cleanupRequired }
            var index = try encoded.map { try JSONDecoder().decode(Index.self, from: $0) } ?? Index()
            guard index.version == 1, index.retained.count <= 33, index.evicting.count <= 33,
                  Set(index.retained).count == index.retained.count,
                  Set(index.evicting).count == index.evicting.count,
                  Set(index.retained).isDisjoint(with: index.evicting),
                  ([scope] + index.retained + index.evicting).allSatisfy({
                      $0.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
                  }) else { throw LatchwayLifecycleError.cleanupRequired }
            // Recover incomplete eviction before allowing even a returning
            // account to use an old namespace. Deleted keys are never restored.
            for old in index.evicting { try await evict(old) }
            index.evicting = []
            index.retained.removeAll { $0 == scope }
            index.retained.append(scope)
            if index.retained.count > limit {
                index.evicting = Array(index.retained.prefix(index.retained.count - limit))
                index.retained.removeFirst(index.evicting.count)
            }
            try records.write(JSONEncoder().encode(index))
            for old in index.evicting { try await evict(old) }
            index.evicting = []
            try records.write(JSONEncoder().encode(index))
        } catch { throw LatchwayLifecycleError.cleanupRequired }
    }
}

struct LatchwayKeyRetentionRecords: LatchwayLifecycleRecords {
    let records: LatchwayKeychainRecords
    func read() throws -> Data? { try records.read(account: "retained-account-keys-v3") }
    func write(_ data: Data) throws { try records.write(data, account: "retained-account-keys-v3") }
}
