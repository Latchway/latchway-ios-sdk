import Foundation
import Latchway
import LatchwayAppExtensions
import Testing

@Test func componentDescriptorAndRecoveryAreExplicit() {
    let component = LatchwayComponentConfiguration.widget(
        definitionID: "ios-widget",
        keychainAccessGroup: "ABCDE12345.com.example.latchway.widget",
        requestedFeatures: ["weekly-summary"]
    )

    #expect(component.kind == "widget")
    #expect(component.requestedFeatures == ["weekly-summary"])
    #expect(LatchwayComponentError.containingAppSetupRequired.recovery.openingContainingAppCanFix)
    #expect(!LatchwayComponentError.componentKeyUnavailable.recovery.immediateRetryUseful)
}

@Test func componentDiagnosticsNeverContainCredentials() {
    let diagnostics = LatchwayComponentDiagnostics(
        familyID: "fam_0000000000000000",
        componentID: "cmp_0000000000000000",
        definitionID: "ios-widget",
        keychainAccessGroup: "ABCDE12345.com.example.latchway.widget",
        keyAvailable: true,
        keyStorage: .secureEnclave,
        grantAvailable: true,
        sessionAvailable: false,
        trustSource: .delegatedFromAttestedRoot,
        trustExpiresAt: Date(timeIntervalSince1970: 2_000_000_000),
        containingAppActionRequired: false
    )

    let mirrorLabels = Set(Mirror(reflecting: diagnostics).children.compactMap(\.label))
    #expect(!mirrorLabels.contains("accessToken"))
    #expect(!mirrorLabels.contains("refreshToken"))
    #expect(!mirrorLabels.contains("refreshGrant"))
}

@Test func unresolvedBuildSettingInAccessGroupFailsClosed() throws {
    let configuration = LatchwayConfiguration(
        baseURL: try #require(URL(string: "https://gateway.example.invalid")),
        applicationID: "app_0000000000000000",
        environment: "development",
        rootKeychainAccessGroup: "ABCDE12345.com.example.latchway"
    )
    let component = LatchwayComponentConfiguration.widget(
        definitionID: "ios-widget",
        keychainAccessGroup: "$(AppIdentifierPrefix)com.example.latchway.widget",
        requestedFeatures: ["weekly-summary"]
    )

    #expect(throws: LatchwayComponentError.self) {
        _ = try LatchwayExtensionClient(
            configuration: configuration,
            component: component
        )
    }
}

@Test func directComponentAttestationSurfaceIsPublic() {
    let operation: (LatchwayExtensionClient) async throws -> Void = { client in
        try await client.establishDirectAttestation()
    }
    _ = operation
    #expect(LatchwayComponentTrustSource.delegatedDirectAttested.rawValue == "delegated_direct_attested")
}
