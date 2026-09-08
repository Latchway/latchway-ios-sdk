import Foundation
import XCTest
@testable import Latchway

final class SharedComponentLifecycleTests: XCTestCase {
    func testComponentIndexEvictsOnlyRequestedInactiveAccountAndRejectsCorruption() throws {
        let firstRecords = ComponentCASMemoryRecords(), secondRecords = ComponentCASMemoryRecords()
        let first = LatchwaySharedComponentState(records: firstRecords, generation: UUID())
        let second = LatchwaySharedComponentState(records: secondRecords, generation: UUID())
        try first.initialize(); try second.initialize()
        try first.write(Data("A-key".utf8), name: "component-key")
        try second.write(Data("B-key".utf8), name: "component-key")
        try first.retire()
        let indexRecords = SharedRootMemoryRecords()
        let index = LatchwaySharedComponentKeyIndex(records: indexRecords) { account, _ in
            account.generationID == first.generation ? first : second
        }
        let component = LatchwayComponentConfiguration.widget(definitionID: "widget",
            keychainAccessGroup: "TEAM.widget", requestedFeatures: ["chat"])
        let a = LatchwayComponentAccount(generationID: first.generation,
            appScope: String(repeating: "a", count: 64), accountScope: String(repeating: "b", count: 64))
        let b = LatchwayComponentAccount(generationID: second.generation,
            appScope: a.appScope, accountScope: String(repeating: "c", count: 64))
        try index.register(account: a, component: component)
        try index.register(account: b, component: component)
        XCTAssertThrowsError(try index.evict(accountScope: b.accountScope)) // Active keys cannot be evicted.
        try index.evict(accountScope: a.accountScope)
        let retired = try JSONDecoder().decode(LatchwaySharedComponentState.Envelope.self,
            from: XCTUnwrap(firstRecords.read()).data)
        XCTAssertTrue(retired.values.isEmpty)
        XCTAssertEqual(try second.read("component-key"), Data("B-key".utf8))
        try indexRecords.write(Data("{}".utf8))
        XCTAssertThrowsError(try index.evict(accountScope: b.accountScope))
        XCTAssertEqual(try second.read("component-key"), Data("B-key".utf8))
    }

    func testRetirementErasesCredentialsAndExplicitEvictionErasesInactiveKeys() throws {
        let records = ComponentCASMemoryRecords()
        let state = LatchwaySharedComponentState(records: records, generation: UUID())
        try state.initialize()
        try state.write(Data("delegated-only".utf8), name: "credential")
        try state.write(Data("component-key-only".utf8), name: "component-key")
        try state.retire()
        let durable = try JSONDecoder().decode(LatchwaySharedComponentState.Envelope.self,
            from: XCTUnwrap(records.read()).data)
        XCTAssertTrue(durable.retired)
        XCTAssertNil(durable.values["credential"])
        XCTAssertEqual(durable.values["component-key"], Data("component-key-only".utf8))
        XCTAssertThrowsError(try state.write(Data("late-token".utf8), name: "credential"))
        XCTAssertThrowsError(try state.initialize())
        try state.retire()
        try state.evictRetiredKeys()
        let evicted = try JSONDecoder().decode(LatchwaySharedComponentState.Envelope.self,
            from: XCTUnwrap(records.read()).data)
        XCTAssertTrue(evicted.values.isEmpty)
    }

    func testIndependentWriterCannotOverwriteRetirementWithStaleRevision() throws {
        let records = ComponentCASMemoryRecords()
        let firstProcess = LatchwaySharedComponentState(records: records, generation: UUID())
        let secondProcess = LatchwaySharedComponentState(records: records, generation: firstProcess.generation)
        try firstProcess.initialize()
        records.beforeNextReplace { try secondProcess.retire() }
        XCTAssertThrowsError(try firstProcess.write(Data("late-refresh".utf8), name: "credential")) {
            XCTAssertEqual($0 as? LatchwayLifecycleError, .loggedOut)
        }
        XCTAssertThrowsError(try secondProcess.check())
    }

    func testCapturedOldRetirementDoesNotRetireNewGeneration() throws {
        let records = ComponentCASMemoryRecords()
        let old = LatchwaySharedComponentState(records: records, generation: UUID())
        try old.initialize()
        try old.retire()
        let next = LatchwaySharedComponentState(records: records, generation: UUID())
        try next.initialize()
        try next.write(Data("B".utf8), name: "credential")
        try old.retire()
        XCTAssertEqual(try next.read("credential"), Data("B".utf8))
        XCTAssertThrowsError(try old.check())
    }

    func testDelayedCredentialCannotOverwriteAnotherProcessRotation() throws {
        let records = ComponentCASMemoryRecords()
        let state = LatchwaySharedComponentState(records: records, generation: UUID())
        try state.initialize()
        let old = Data("old".utf8), fresh = Data("new".utf8)
        try state.writeCredential(old, replacing: nil)
        let captured = try state.read("credential")
        try state.writeCredential(fresh, replacing: old)
        XCTAssertThrowsError(try state.writeCredential(Data("late".utf8), replacing: captured))
        XCTAssertThrowsError(try state.writeCredential(nil, replacing: captured))
        XCTAssertEqual(try state.read("credential"), fresh)
    }

    func testMissingCorruptAndContentionExhaustedMarkersFailClosed() throws {
        let records = ComponentCASMemoryRecords()
        let state = LatchwaySharedComponentState(records: records, generation: UUID())
        XCTAssertThrowsError(try state.check())
        try state.retire() // Missing state receives a tombstone, never an active credential.
        XCTAssertThrowsError(try state.initialize())
        records.corrupt(Data("{}".utf8))
        XCTAssertThrowsError(try state.retire())
        let contended = ComponentCASMemoryRecords()
        contended.alwaysConflict = true
        XCTAssertThrowsError(try LatchwaySharedComponentState(records: contended, generation: UUID()).initialize())
        XCTAssertEqual(contended.attempts, 32)
    }

    func testBufferedExtensionBytesRecheckIndependentRetirement() async throws {
        let records = ComponentCASMemoryRecords()
        let state = LatchwaySharedComponentState(records: records, generation: UUID())
        try state.initialize()
        var reader = LatchwayAsyncBytes(buffered: Data("old account reply".utf8))
            .withPersistentCheck { try state.check() }.makeAsyncIterator()
        let first = try await reader.next()
        XCTAssertNotNil(first)
        try LatchwaySharedComponentState(records: records, generation: state.generation).retire()
        do { _ = try await reader.next(); XCTFail("A buffered old-account byte escaped the durable fence") }
        catch { XCTAssertEqual(error as? LatchwayLifecycleError, .loggedOut) }
    }

    func testRootJournalCannotFinishUntilEveryComponentTombstonePersists() async throws {
        let rootRecords = SharedRootMemoryRecords()
        let componentRecords = ComponentCASMemoryRecords()
        let journal = LatchwayAppSessionJournal(records: rootRecords, componentState: { account, _ in
            .init(records: componentRecords, generation: account.generationID)
        })
        let active = try await journal.activate(account: "A")
        let account = LatchwayComponentAccount(generationID: active.generation,
            appScope: String(repeating: "a", count: 64), accountScope: String(repeating: "b", count: 64))
        let component = LatchwayComponentConfiguration.widget(definitionID: "widget",
            keychainAccessGroup: "TEAM.widget", requestedFeatures: ["chat"])
        try await journal.registerComponent(component, account: account)
        try await journal.retire(active.generation)
        componentRecords.failWrites = true
        do { try await journal.finishRetirement(active.generation); XCTFail("False cleanup success") }
        catch { XCTAssertEqual(error as? LatchwayLifecycleError, .cleanupRequired) }
        do { _ = try await journal.activate(account: "B"); XCTFail("Account B bypassed component cleanup") }
        catch { XCTAssertEqual(error as? LatchwayLifecycleError, .cleanupRequired) }
        componentRecords.failWrites = false
        let restarted = LatchwayAppSessionJournal(records: rootRecords, componentState: { account, _ in
            .init(records: componentRecords, generation: account.generationID)
        })
        try await restarted.finishRetirement(active.generation)
        _ = try await restarted.activate(account: "B")
        XCTAssertThrowsError(try LatchwaySharedComponentState(records: componentRecords,
            generation: active.generation).check())
    }
}

/// Test-only simulation of independent processes sharing one transactional
/// backing store. Every mutable field is protected by the same NSLock.
final class ComponentCASMemoryRecords: LatchwayRevisionedRecords, @unchecked Sendable {
    private let lock = NSLock()
    private var value: LatchwayRevisionedValue?
    private var hook: (@Sendable () throws -> Void)?
    private var conflict = false
    private var failure = false
    private var count = 0
    var alwaysConflict: Bool { get { lock.withLock { conflict } } set { lock.withLock { conflict = newValue } } }
    var failWrites: Bool { get { lock.withLock { failure } } set { lock.withLock { failure = newValue } } }
    var attempts: Int { lock.withLock { count } }
    func beforeNextReplace(_ callback: @escaping @Sendable () throws -> Void) { lock.withLock { hook = callback } }
    func corrupt(_ data: Data) { lock.withLock { value = .init(revision: Data(repeating: 0, count: 16), data: data) } }
    func read() throws -> LatchwayRevisionedValue? { lock.withLock { value } }
    func replace(expected: Data?, value next: LatchwayRevisionedValue) throws -> Bool {
        let callback = lock.withLock { let next = hook; hook = nil; return next }
        try callback?()
        return try lock.withLock {
            count += 1
            if failure { throw LatchwayLifecycleError.cleanupRequired }
            guard !conflict, expected == value?.revision else { return false }
            value = next
            return true
        }
    }
}

private final class SharedRootMemoryRecords: LatchwayLifecycleRecords, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    func read() throws -> Data? { lock.withLock { value } }
    func write(_ data: Data) throws { lock.withLock { value = data } }
}
