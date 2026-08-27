import Foundation
import Latchway
@testable import LatchwayAppAttest
import XCTest

final class AppAttestLifecycleTests: XCTestCase {
    func testRegistrationThenAssertion() async throws {
        let service = FakeService()
        let store = MemoryStateStore()
        let provider = LatchwayAppAttestProvider(service: service, stateStore: store)
        let challenge = fixtureChallenge()

        let registration = try await provider.evidence(for: challenge)
        XCTAssertNotNil(registration.evidence["attestation_object"])
        XCTAssertNil(registration.evidence["assertion_object"])
        await provider.didAccept(registration)

        let assertion = try await provider.evidence(for: challenge)
        XCTAssertNil(assertion.evidence["attestation_object"])
        XCTAssertNotNil(assertion.evidence["assertion_object"])
        let counts = await service.counts()
        XCTAssertEqual(counts.generateKey, 1)
        XCTAssertEqual(counts.attestation, 1)
        XCTAssertEqual(counts.assertion, 1)
    }

    func testInvalidKeyRecoveryIsBoundedToOneRotation() async throws {
        let service = FakeService(assertionFailures: [.invalidKey])
        let store = MemoryStateStore(initial: .init(keyID: "stale", acceptedByLatchway: true))
        let provider = LatchwayAppAttestProvider(service: service, stateStore: store)
        let evidence = try await provider.evidence(for: fixtureChallenge())
        XCTAssertNotNil(evidence.evidence["attestation_object"])
        let counts = await service.counts()
        let status = await provider.status()
        XCTAssertEqual(counts.generateKey, 1)
        XCTAssertEqual(status.lastOperation, "attestation")
    }

    func testSecondInvalidKeyFailsWithoutInfiniteRecovery() async {
        let service = FakeService(attestationFailures: [.invalidKey], assertionFailures: [.invalidKey])
        let store = MemoryStateStore(initial: .init(keyID: "stale", acceptedByLatchway: true))
        let provider = LatchwayAppAttestProvider(service: service, stateStore: store)
        do {
            _ = try await provider.evidence(for: fixtureChallenge())
            XCTFail("Expected bounded recovery to fail")
        } catch let error as LatchwayError {
            XCTAssertEqual(error, .attestationUnavailable)
            let counts = await service.counts()
            XCTAssertEqual(counts.generateKey, 1)
            XCTAssertEqual(counts.attestation, 1)
        } catch {
            XCTFail("Expected a stable LatchwayError, got \(type(of: error))")
        }
    }

    func testInvalidClientDataHashFailsClosed() async {
        let provider = LatchwayAppAttestProvider(service: FakeService(), stateStore: MemoryStateStore())
        let challenge = LatchwayAttestationChallenge(
            id: "chl_01J00000000000000000000000",
            provider: "app_attest",
            clientDataHash: Data(repeating: 0, count: 31),
            expiresAt: Date().addingTimeInterval(60)
        )
        await XCTAssertThrowsErrorAsync { _ = try await provider.evidence(for: challenge) }
    }

    func testKeyCreationFailureUsesStableRedactedError() async {
        let provider = LatchwayAppAttestProvider(
            service: FakeService(generateKeyFailures: [.serverUnavailable]),
            stateStore: MemoryStateStore()
        )
        do {
            _ = try await provider.evidence(for: fixtureChallenge())
            XCTFail("Expected App Attest key creation to fail")
        } catch let error as LatchwayError {
            XCTAssertEqual(error, .attestationUnavailable)
        } catch {
            XCTFail("Expected a stable LatchwayError, got \(type(of: error))")
        }
    }

    private func fixtureChallenge() -> LatchwayAttestationChallenge {
        LatchwayAttestationChallenge(
            id: "chl_01J00000000000000000000000",
            provider: "app_attest",
            clientDataHash: Data(repeating: 7, count: 32),
            expiresAt: Date().addingTimeInterval(300)
        )
    }
}

private actor FakeService: AppAttestServicing {
    private var generateKeyFailures: [AppAttestOperationError]
    private var attestationFailures: [AppAttestOperationError]
    private var assertionFailures: [AppAttestOperationError]
    private(set) var generateKeyCount = 0
    private(set) var attestationCount = 0
    private(set) var assertionCount = 0

    init(
        generateKeyFailures: [AppAttestOperationError] = [],
        attestationFailures: [AppAttestOperationError] = [],
        assertionFailures: [AppAttestOperationError] = []
    ) {
        self.generateKeyFailures = generateKeyFailures
        self.attestationFailures = attestationFailures
        self.assertionFailures = assertionFailures
    }

    func isSupported() async -> Bool { true }
    func generateKey() async throws -> String {
        generateKeyCount += 1
        if !generateKeyFailures.isEmpty { throw generateKeyFailures.removeFirst() }
        return "generated-key-\(generateKeyCount)"
    }
    func attestKey(keyID _: String, clientDataHash _: Data) async throws -> Data {
        attestationCount += 1
        if !attestationFailures.isEmpty { throw attestationFailures.removeFirst() }
        return Data("attestation".utf8)
    }
    func generateAssertion(keyID _: String, clientDataHash _: Data) async throws -> Data {
        assertionCount += 1
        if !assertionFailures.isEmpty { throw assertionFailures.removeFirst() }
        return Data("assertion".utf8)
    }

    func counts() -> (generateKey: Int, attestation: Int, assertion: Int) {
        (generateKeyCount, attestationCount, assertionCount)
    }
}

private actor MemoryStateStore: AppAttestStateStoring {
    private var state: LatchwayAppAttestProvider.State?
    init(initial: LatchwayAppAttestProvider.State? = nil) { state = initial }
    func load() async throws -> LatchwayAppAttestProvider.State? { state }
    func save(_ state: LatchwayAppAttestProvider.State) async throws { self.state = state }
    func clear() async throws { state = nil }
}

private func XCTAssertThrowsErrorAsync(
    _ operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
