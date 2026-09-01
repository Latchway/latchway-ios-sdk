import Foundation
@testable import Latchway
import XCTest

final class ComponentRegistryTests: XCTestCase {
    func testRegistryPersistsOnlyValidatedPublicDescriptorsAcrossInstances() async throws {
        let store = ComponentRegistryMemoryStore()
        let first = LatchwayKeychainComponentRegistry(store: store)
        let widget = component(
            definitionID: "home_widget",
            kind: "widget",
            accessGroup: "TEAM123456.com.example.widget",
            features: ["habit_assistant"]
        )
        let movedWidget = component(
            definitionID: "home_widget",
            kind: "widget",
            accessGroup: "TEAM123456.com.example.widget-v2",
            features: ["habit_assistant"]
        )

        try await first.register(widget)
        try await first.register(component(
            definitionID: widget.definitionID,
            kind: widget.kind,
            accessGroup: widget.keychainAccessGroup,
            features: ["habit_assistant", "habit_summary"]
        ))
        try await first.register(movedWidget)

        let relaunched = LatchwayKeychainComponentRegistry(store: store)
        let restored = try await relaunched.components()
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored[0].keychainAccessGroup, widget.keychainAccessGroup)
        XCTAssertEqual(restored[0].requestedFeatures, ["habit_assistant", "habit_summary"])
        XCTAssertEqual(restored[1], movedWidget)

        try await relaunched.unregister(widget)
        let afterUnregister = try await first.components()
        XCTAssertEqual(afterUnregister, [movedWidget])
        let storedData = await store.data(for: LatchwayKeychainComponentRegistry.account)
        let encoded = try XCTUnwrap(storedData)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(text.contains("token"))
        XCTAssertFalse(text.contains("private"))
        XCTAssertTrue(text.contains("TEAM123456.com.example.widget-v2"))
    }

    func testRegistryRejectsMalformedStoredEntryWithoutDeletingRetryEvidence() async throws {
        let malformed = Data(#"{"version":1,"entries":[{"definitionID":"../bad","kind":"widget","keychainAccessGroup":"TEAM123456.com.example.widget","requestedFeatures":["habit_assistant"]}]}"#.utf8)
        let store = ComponentRegistryMemoryStore(initial: malformed)
        let registry = LatchwayKeychainComponentRegistry(store: store)

        do {
            _ = try await registry.components()
            XCTFail("Expected malformed registry rejection")
        } catch let error as LatchwayError {
            XCTAssertEqual(error, .keyStorageFailure)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let retained = await store.data(for: LatchwayKeychainComponentRegistry.account)
        XCTAssertEqual(retained, malformed)
    }

    func testRegistryRejectsUnknownCredentialLikeStoredFields() async throws {
        let malformed = Data(#"{"version":1,"entries":[{"definitionID":"home_widget","kind":"widget","keychainAccessGroup":"TEAM123456.com.example.widget","requestedFeatures":["habit_assistant"],"refreshToken":"must-not-be-accepted"}]}"#.utf8)
        let store = ComponentRegistryMemoryStore(initial: malformed)
        let registry = LatchwayKeychainComponentRegistry(store: store)

        do {
            _ = try await registry.components()
            XCTFail("Expected unknown registry field rejection")
        } catch let error as LatchwayError {
            XCTAssertEqual(error, .keyStorageFailure)
        }
        let retained = await store.data(for: LatchwayKeychainComponentRegistry.account)
        XCTAssertEqual(retained, malformed)
    }

    func testRegistrySerializesReadModifyWriteAcrossClientInstances() async throws {
        let store = ComponentRegistryMemoryStore()
        let first = LatchwayKeychainComponentRegistry(
            store: store,
            lockIdentity: "shared-installation"
        )
        let second = LatchwayKeychainComponentRegistry(
            store: store,
            lockIdentity: "shared-installation"
        )
        let components = (0 ..< 32).map { index in
            LatchwayComponentConfiguration(
                definitionID: "widget_\(index)",
                kind: "widget",
                keychainAccessGroup: "TEAM123456.com.example.widget-\(index)",
                requestedFeatures: ["habit_assistant"]
            )
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, component) in components.enumerated() {
                let registry = index.isMultiple(of: 2) ? first : second
                group.addTask { try await registry.register(component) }
            }
            try await group.waitForAll()
        }

        let restored = try await first.components()
        XCTAssertEqual(Set(restored.map(\.definitionID)), Set(components.map(\.definitionID)))
    }

    func testPreflightFailureDoesNotReadOrMutateRegistry() async throws {
        let store = ComponentRegistryMemoryStore()
        let registry = LatchwayKeychainComponentRegistry(
            store: store,
            rootKeychainPreflight: { throw LatchwayError.rootKeychainMigrationRequired }
        )

        do {
            try await registry.register(component())
            XCTFail("Expected migration rejection")
        } catch let error as LatchwayError {
            XCTAssertEqual(error, .rootKeychainMigrationRequired)
        }
        let operationCount = await store.operationCount()
        XCTAssertEqual(operationCount, 0)
    }

    func testFamilyRetirementAttemptsAllEntriesAndRetainsOnlyFailuresForRetry() async throws {
        let store = ComponentRegistryMemoryStore()
        let registry = LatchwayKeychainComponentRegistry(store: store)
        let widget = component()
        let share = component(
            definitionID: "share_extension",
            kind: "share_extension",
            accessGroup: "TEAM123456.com.example.share",
            features: ["habit_summary"]
        )
        let legacy = component(
            definitionID: "legacy_intent",
            kind: "app_intent_extension",
            accessGroup: "TEAM123456.com.example.legacy-intent",
            features: ["habit_assistant"]
        )
        try await registry.register(widget)
        try await registry.register(share)
        let recorder = ComponentRetirementRecorder(failingDefinitionIDs: [share.definitionID])

        do {
            try await LatchwayComponentFamilyRetirement.retireAll(
                registry: registry,
                including: [widget, legacy],
                retire: { component in try await recorder.retire(component) }
            )
            XCTFail("Expected one cleanup failure")
        } catch let error as LatchwayComponentError {
            XCTAssertEqual(error, .keychainAccessGroupUnavailable)
        }

        let attempts = await recorder.attempts()
        XCTAssertEqual(
            Set(attempts),
            Set([widget.definitionID, share.definitionID, legacy.definitionID])
        )
        let remaining = try await registry.components()
        XCTAssertEqual(remaining, [share])

        await recorder.allowAll()
        try await LatchwayComponentFamilyRetirement.retireAll(
            registry: registry,
            including: [],
            retire: { component in try await recorder.retire(component) }
        )
        let finalComponents = try await registry.components()
        XCTAssertEqual(finalComponents, [])
        let finalData = await store.data(for: LatchwayKeychainComponentRegistry.account)
        XCTAssertNil(finalData)
    }

    private func component(
        definitionID: String = "home_widget",
        kind: String = "widget",
        accessGroup: String = "TEAM123456.com.example.widget",
        features: [String] = ["habit_assistant"]
    ) -> LatchwayComponentConfiguration {
        LatchwayComponentConfiguration(
            definitionID: definitionID,
            kind: kind,
            keychainAccessGroup: accessGroup,
            requestedFeatures: features
        )
    }
}

private actor ComponentRegistryMemoryStore: LatchwaySecureDataStoring {
    private var values: [String: Data]
    private var operations = 0

    init(initial: Data? = nil) {
        values = initial.map { [LatchwayKeychainComponentRegistry.account: $0] } ?? [:]
    }

    func read(account: String) -> Data? {
        operations += 1
        return values[account]
    }

    func write(_ data: Data, account: String) {
        operations += 1
        values[account] = data
    }

    func delete(account: String) {
        operations += 1
        values.removeValue(forKey: account)
    }

    func data(for account: String) -> Data? { values[account] }
    func operationCount() -> Int { operations }
}

private actor ComponentRetirementRecorder {
    private var failingDefinitionIDs: Set<String>
    private var retired: [String] = []

    init(failingDefinitionIDs: Set<String>) {
        self.failingDefinitionIDs = failingDefinitionIDs
    }

    func retire(_ component: LatchwayComponentConfiguration) throws {
        retired.append(component.definitionID)
        if failingDefinitionIDs.contains(component.definitionID) {
            throw LatchwayComponentError.keychainAccessGroupUnavailable
        }
    }

    func attempts() -> [String] { retired }
    func allowAll() { failingDefinitionIDs = [] }
}
