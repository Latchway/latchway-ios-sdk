import Foundation
import Latchway

struct PhysicalComponentCheckpoint: Codable {
    let schemaVersion: String
    let runID: String
    let startedAt: String
    let tests: [EvidenceTest]

    enum CodingKeys: String, CodingKey {
        case tests
        case schemaVersion = "schema_version"
        case runID = "run_id"
        case startedAt = "started_at"
    }
}

enum PhysicalComponentProducer {
    static let readyRelativePath = "Documents/latchway-component-producer-ready.json"
    static let completionRelativePath = "Documents/latchway-component-observer-complete.json"

    private static let checkpointName = "latchway-component-producer-checkpoint.json"
    private static let readyName = "latchway-component-producer-ready.json"
    private static let completionName = "latchway-component-observer-complete.json"

    static func loadCheckpoint(runID: String) throws -> PhysicalComponentCheckpoint? {
        let path = try documentURL(name: checkpointName)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let data = try boundedData(at: path)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any],
              Set(dictionary.keys) == ["schema_version", "run_id", "started_at", "tests"]
        else { throw ProducerError.invalidCheckpoint }
        let value = try decoder.decode(PhysicalComponentCheckpoint.self, from: data)
        let testIDs = Set(value.tests.map(\.id))
        guard value.schemaVersion == "latchway.ios-component-producer-checkpoint.v1",
              value.runID == runID,
              !value.startedAt.isEmpty,
              testIDs.count == value.tests.count,
              testIDs == EvidencePolicy.preObserverTests,
              value.tests.allSatisfy({ $0.status == "passed" })
        else { throw ProducerError.invalidCheckpoint }
        return value
    }

    static func stage(
        client: LatchwayClient,
        runID: String,
        startedAt: String,
        tests: [EvidenceTest]
    ) async throws {
        let configurations = try ComponentExampleConfiguration.delegatedComponents()
        let diagnostics = try await client.prepareComponents(configurations)
        guard diagnostics.count == configurations.count else {
            throw ProducerError.componentPreparationFailed
        }
        guard Set(diagnostics.map(\.definitionID)).count == diagnostics.count else {
            throw ProducerError.componentPreparationFailed
        }
        let familyIDs = diagnostics.compactMap(\.familyID)
        let componentIDs = diagnostics.compactMap(\.componentID)
        guard familyIDs.count == diagnostics.count,
              Set(familyIDs).count == 1,
              componentIDs.count == diagnostics.count,
              Set(componentIDs).count == diagnostics.count
        else { throw ProducerError.componentPreparationFailed }
        let byDefinition = Dictionary(uniqueKeysWithValues: diagnostics.map { ($0.definitionID, $0) })
        let now = Date()
        for configuration in configurations {
            guard let diagnostic = byDefinition[configuration.definitionID],
                  diagnostic.keychainAccessGroup == configuration.keychainAccessGroup,
                  diagnostic.keyAvailable,
                  diagnostic.keyStorage == .secureEnclave,
                  diagnostic.grantAvailable,
                  !diagnostic.sessionAvailable,
                  diagnostic.trustSource == .delegatedFromAttestedRoot,
                  diagnostic.trustExpiresAt.map({ $0 > now }) == true,
                  !diagnostic.containingAppActionRequired
            else { throw ProducerError.componentPreparationFailed }
        }

        let checkpoint = PhysicalComponentCheckpoint(
            schemaVersion: "latchway.ios-component-producer-checkpoint.v1",
            runID: runID,
            startedAt: startedAt,
            tests: tests
        )
        try write(checkpoint, to: documentURL(name: checkpointName))
        try writeReadyMarker(runID: runID, configurations: configurations)
    }

    static func ensureReadyMarker(runID: String) throws {
        let path = try documentURL(name: readyName)
        let configurations = try ComponentExampleConfiguration.delegatedComponents()
        let expected = try readyMarker(runID: runID, configurations: configurations)
        if FileManager.default.fileExists(atPath: path.path) {
            let existing = try decoder.decode(ReadyMarker.self, from: boundedData(at: path))
            guard existing == expected else { throw ProducerError.invalidReadyMarker }
            return
        }
        try write(expected, to: path)
    }

    static func observerCompleted(runID: String) throws -> Bool {
        let path = try documentURL(name: completionName)
        guard FileManager.default.fileExists(atPath: path.path) else { return false }
        let data = try boundedData(at: path)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any],
              Set(dictionary.keys) == ["schema_version", "run_id"],
              dictionary["schema_version"] as? String == "latchway.ios-component-observer-completion.v1",
              dictionary["run_id"] as? String == runID
        else { throw ProducerError.invalidObserverCompletion }
        return true
    }

    static func removeCoordinationFiles() throws {
        for name in [checkpointName, readyName, completionName] {
            let path = try documentURL(name: name)
            if FileManager.default.fileExists(atPath: path.path) {
                try FileManager.default.removeItem(at: path)
            }
        }
    }

    private static func writeReadyMarker(
        runID: String,
        configurations: [LatchwayComponentConfiguration]
    ) throws {
        try write(
            readyMarker(runID: runID, configurations: configurations),
            to: documentURL(name: readyName)
        )
    }

    private static func readyMarker(
        runID: String,
        configurations: [LatchwayComponentConfiguration]
    ) throws -> ReadyMarker {
        guard configurations.count == 3 else {
            throw ProducerError.invalidCandidateIdentity
        }
        let hostDefinitionID = try ComponentExampleConfiguration.hostDefinitionID()
        let hostBundleID = Bundle.main.bundleIdentifier ?? ""
        let roles: [(String, String, String, String)] = [
            ("host", "main_app", hostDefinitionID, hostBundleID),
            ("widget", "widget", configurations[0].definitionID, try requiredInfo("LatchwayWidgetBundleID")),
            ("share", "share_extension", configurations[1].definitionID, try requiredInfo("LatchwayShareBundleID")),
            ("action", "action_extension", configurations[2].definitionID, try requiredInfo("LatchwayActionBundleID")),
        ]
        guard !hostBundleID.isEmpty,
              Set(roles.map { $0.2 }).count == roles.count,
              Set(roles.map { $0.3 }).count == roles.count
        else { throw ProducerError.invalidCandidateIdentity }

        return ReadyMarker(
            schemaVersion: "latchway.ios-component-producer-ready.v1",
            runID: runID,
            phase: "delegated_credentials_prepared",
            components: roles.map {
                .init(role: $0.0, kind: $0.1, definitionID: $0.2, bundleIdentifier: $0.3)
            }
        )
    }

    private static func requiredInfo(_ key: String) throws -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty
        else { throw ProducerError.invalidCandidateIdentity }
        return value
    }

    private static func documentURL(name: String) throws -> URL {
        let directory = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return directory.appendingPathComponent(name, isDirectory: false)
    }

    private static func boundedData(at path: URL) throws -> Data {
        let values = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              (1 ... 262_144).contains(size)
        else { throw ProducerError.unsafeCoordinationFile }
        return try Data(contentsOf: path, options: [.mappedIfSafe])
    }

    private static func write<T: Encodable>(_ value: T, to path: URL) throws {
        let data = try encoder.encode(value)
        guard data.count <= 262_144 else { throw ProducerError.unsafeCoordinationFile }
        try data.write(to: path, options: [.atomic, .completeFileProtection])
    }

    private static let encoder: JSONEncoder = {
        let value = JSONEncoder()
        value.outputFormatting = [.sortedKeys]
        return value
    }()

    private static let decoder = JSONDecoder()
}

private struct ReadyMarker: Codable, Equatable {
    struct Component: Codable, Equatable {
        let role: String
        let kind: String
        let definitionID: String
        let bundleIdentifier: String

        enum CodingKeys: String, CodingKey {
            case role, kind
            case definitionID = "definition_id"
            case bundleIdentifier = "bundle_identifier"
        }
    }

    let schemaVersion: String
    let runID: String
    let phase: String
    let components: [Component]

    enum CodingKeys: String, CodingKey {
        case phase, components
        case schemaVersion = "schema_version"
        case runID = "run_id"
    }
}

private enum ProducerError: Error {
    case componentPreparationFailed
    case invalidCandidateIdentity
    case invalidCheckpoint
    case invalidObserverCompletion
    case invalidReadyMarker
    case unsafeCoordinationFile
}
