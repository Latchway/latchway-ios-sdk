import ProjectDescription

let bundleID = Environment.latchwayConformanceBundleID.getString(
    default: "dev.latchway.conformance"
)
let widgetBundleID = Environment.latchwayConformanceWidgetBundleID.getString(
    default: "\(bundleID).widget"
)
let shareBundleID = Environment.latchwayConformanceShareBundleID.getString(
    default: "\(bundleID).share"
)
let actionBundleID = Environment.latchwayConformanceActionBundleID.getString(
    default: "\(bundleID).action"
)
let developmentTeam = Environment.latchwayDevelopmentTeam.getString(default: "")
let appAttestEnvironment = Environment.latchwayAppAttestEnvironment.getString(
    default: "development"
)
let marketingVersion = Environment.latchwayConformanceVersion.getString(default: "1.0.0")
let buildNumber = Environment.latchwayConformanceBuild.getString(default: "1")
let gatewayURL = Environment.latchwayGatewayURL.getString(
    default: "https://gateway.example.invalid"
)
let applicationID = Environment.latchwayApplicationID.getString(
    default: "app_00000000000000000000000000"
)
let latchwayEnvironment = Environment.latchwayEnvironment.getString(default: "development")
let identityProvider = Environment.latchwayIdentityProvider.getString(default: "firebase")
let hostDefinitionID = Environment.latchwayHostComponentDefinitionID.getString(
    default: "host_app"
)
let widgetDefinitionID = Environment.latchwayWidgetComponentDefinitionID.getString(
    default: "home_widget"
)
let shareDefinitionID = Environment.latchwayShareComponentDefinitionID.getString(
    default: "share_extension"
)
let actionDefinitionID = Environment.latchwayActionComponentDefinitionID.getString(
    default: "action_extension"
)
let widgetFeature = Environment.latchwayWidgetFeature.getString(default: "weekly-summary")
let shareFeature = Environment.latchwayShareFeature.getString(default: "chat")
let actionFeature = Environment.latchwayActionFeature.getString(default: "chat")
let widgetGroupSuffix = Environment.latchwayWidgetKeychainGroupSuffix.getString(
    default: widgetBundleID
)
let shareGroupSuffix = Environment.latchwayShareKeychainGroupSuffix.getString(
    default: shareBundleID
)
let actionGroupSuffix = Environment.latchwayActionKeychainGroupSuffix.getString(
    default: actionBundleID
)
let codeSignStyle = Environment.latchwayCodeSignStyle.getString(default: "Automatic")
let hostProfile = Environment.latchwayHostProvisioningProfileSpecifier.getString(default: "")
let widgetProfile = Environment.latchwayWidgetProvisioningProfileSpecifier.getString(default: "")
let shareProfile = Environment.latchwayShareProvisioningProfileSpecifier.getString(default: "")
let actionProfile = Environment.latchwayActionProvisioningProfileSpecifier.getString(default: "")

guard ["development", "production"].contains(appAttestEnvironment) else {
    fatalError(
        "TUIST_LATCHWAY_APP_ATTEST_ENVIRONMENT must be development or production"
    )
}
guard ["Automatic", "Manual"].contains(codeSignStyle) else {
    fatalError("TUIST_LATCHWAY_CODE_SIGN_STYLE must be Automatic or Manual")
}
let identifiers = [bundleID, widgetBundleID, shareBundleID, actionBundleID]
guard Set(identifiers).count == identifiers.count else {
    fatalError("The host, Widget, Share, and Action bundle identifiers must be distinct")
}
let definitions = [hostDefinitionID, widgetDefinitionID, shareDefinitionID, actionDefinitionID]
guard Set(definitions).count == definitions.count else {
    fatalError("The host, Widget, Share, and Action definition identifiers must be distinct")
}
let accessGroupSuffixes = [bundleID, widgetGroupSuffix, shareGroupSuffix, actionGroupSuffix]
guard Set(accessGroupSuffixes).count == accessGroupSuffixes.count else {
    fatalError("The root and every delegated component must use distinct Keychain access groups")
}
if codeSignStyle == "Manual" {
    guard !developmentTeam.isEmpty,
          !hostProfile.isEmpty,
          !widgetProfile.isEmpty,
          !shareProfile.isEmpty,
          !actionProfile.isEmpty
    else {
        fatalError(
            "Manual signing requires a Team ID and one external provisioning-profile specifier per target"
        )
    }
}

let hostAccessGroup = "$(AppIdentifierPrefix)\(bundleID)"
let widgetAccessGroup = "$(AppIdentifierPrefix)\(widgetGroupSuffix)"
let shareAccessGroup = "$(AppIdentifierPrefix)\(shareGroupSuffix)"
let actionAccessGroup = "$(AppIdentifierPrefix)\(actionGroupSuffix)"

let commonInfo: [String: Plist.Value] = [
    "CFBundleShortVersionString": "$(MARKETING_VERSION)",
    "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
    "LatchwayApplicationID": .string(applicationID),
    "LatchwayActionBundleID": .string(actionBundleID),
    "LatchwayEnvironment": .string(latchwayEnvironment),
    "LatchwayIdentityProvider": .string(identityProvider),
    "LatchwayGatewayURL": .string(gatewayURL),
    "LatchwayRootKeychainAccessGroup": .string(hostAccessGroup),
    "LatchwayHostComponentDefinitionID": .string(hostDefinitionID),
    "LatchwayShareBundleID": .string(shareBundleID),
    "LatchwayWidgetComponentDefinitionID": .string(widgetDefinitionID),
    "LatchwayWidgetFeature": .string(widgetFeature),
    "LatchwayWidgetKeychainAccessGroup": .string(widgetAccessGroup),
    "LatchwayShareComponentDefinitionID": .string(shareDefinitionID),
    "LatchwayShareFeature": .string(shareFeature),
    "LatchwayShareKeychainAccessGroup": .string(shareAccessGroup),
    "LatchwayWidgetBundleID": .string(widgetBundleID),
    "LatchwayActionComponentDefinitionID": .string(actionDefinitionID),
    "LatchwayActionFeature": .string(actionFeature),
    "LatchwayActionKeychainAccessGroup": .string(actionAccessGroup),
]

let baseSettings: SettingsDictionary = [
    "CODE_SIGN_STYLE": .string(codeSignStyle),
    "CURRENT_PROJECT_VERSION": .string(buildNumber),
    "MARKETING_VERSION": .string(marketingVersion),
    "SWIFT_STRICT_CONCURRENCY": "complete",
    "SWIFT_VERSION": "6.0",
]

func settings(profile: String, applicationExtension: Bool = false) -> Settings {
    var values = baseSettings
    if !developmentTeam.isEmpty {
        values["DEVELOPMENT_TEAM"] = .string(developmentTeam)
    }
    if codeSignStyle == "Manual" {
        values["PROVISIONING_PROFILE_SPECIFIER"] = .string(profile)
    }
    if applicationExtension {
        values["APPLICATION_EXTENSION_API_ONLY"] = "YES"
    }
    return .settings(base: values)
}

let project = Project(
    name: "AppAttestConformance",
    options: .options(automaticSchemesOptions: .disabled),
    packages: [
        .local(path: "../.."),
    ],
    targets: [
        .target(
            name: "AppAttestConformance",
            destinations: .iOS,
            product: .app,
            bundleId: bundleID,
            deploymentTargets: .iOS("15.0"),
            infoPlist: .extendingDefault(with: commonInfo.merging([
                "CFBundleDisplayName": "Latchway Conformance",
                "LatchwayAppAttestEnvironment": .string(appAttestEnvironment),
                "UILaunchScreen": [:],
            ]) { _, new in new }),
            sources: [
                "Sources/**",
                "../AppExtensionComponents/Shared/**",
            ],
            entitlements: .dictionary([
                "com.apple.developer.devicecheck.appattest-environment": .string(appAttestEnvironment),
                "keychain-access-groups": [
                    .string(hostAccessGroup),
                    .string(widgetAccessGroup),
                    .string(shareAccessGroup),
                    .string(actionAccessGroup),
                ],
            ]),
            dependencies: [
                .target(name: "ComponentWidget"),
                .target(name: "ComponentShare"),
                .target(name: "ComponentAction"),
                .package(product: "Latchway"),
                .package(product: "LatchwayAppAttest"),
                .package(product: "LatchwayAppExtensions"),
            ],
            settings: settings(profile: hostProfile)
        ),
        .target(
            name: "ComponentWidget",
            destinations: .iOS,
            product: .appExtension,
            bundleId: widgetBundleID,
            deploymentTargets: .iOS("15.0"),
            infoPlist: .extendingDefault(with: commonInfo.merging([
                "CFBundleDisplayName": "Latchway Conformance Widget",
                "NSExtension": [
                    "NSExtensionPointIdentifier": "com.apple.widgetkit-extension",
                ],
            ]) { _, new in new }),
            sources: [
                "../AppExtensionComponents/Widget/**",
                "../AppExtensionComponents/Shared/**",
            ],
            entitlements: .dictionary([
                "keychain-access-groups": [.string(widgetAccessGroup)],
            ]),
            dependencies: [
                .package(product: "Latchway"),
                .package(product: "LatchwayAppExtensions"),
            ],
            settings: settings(profile: widgetProfile, applicationExtension: true)
        ),
        .target(
            name: "ComponentShare",
            destinations: .iOS,
            product: .appExtension,
            bundleId: shareBundleID,
            deploymentTargets: .iOS("15.0"),
            infoPlist: .extendingDefault(with: commonInfo.merging([
                "CFBundleDisplayName": "Latchway Conformance Share",
                "NSExtension": [
                    "NSExtensionAttributes": [
                        "NSExtensionActivationRule": [
                            "NSExtensionActivationSupportsText": true,
                        ],
                    ],
                    "NSExtensionPointIdentifier": "com.apple.share-services",
                    "NSExtensionPrincipalClass": "$(PRODUCT_MODULE_NAME).ComponentShareViewController",
                ],
            ]) { _, new in new }),
            sources: [
                "../AppExtensionComponents/Share/**",
                "../AppExtensionComponents/Shared/**",
            ],
            entitlements: .dictionary([
                "keychain-access-groups": [.string(shareAccessGroup)],
            ]),
            dependencies: [
                .package(product: "Latchway"),
                .package(product: "LatchwayAppExtensions"),
            ],
            settings: settings(profile: shareProfile, applicationExtension: true)
        ),
        .target(
            name: "ComponentAction",
            destinations: .iOS,
            product: .appExtension,
            bundleId: actionBundleID,
            deploymentTargets: .iOS("15.0"),
            infoPlist: .extendingDefault(with: commonInfo.merging([
                "CFBundleDisplayName": "Latchway Conformance Action",
                "NSExtension": [
                    "NSExtensionAttributes": [
                        "NSExtensionActivationRule": [
                            "NSExtensionActivationSupportsText": true,
                        ],
                    ],
                    "NSExtensionPointIdentifier": "com.apple.ui-services",
                    "NSExtensionPrincipalClass": "$(PRODUCT_MODULE_NAME).ComponentActionViewController",
                ],
            ]) { _, new in new }),
            sources: [
                "../AppExtensionComponents/Action/**",
                "../AppExtensionComponents/Shared/**",
            ],
            entitlements: .dictionary([
                "keychain-access-groups": [.string(actionAccessGroup)],
            ]),
            dependencies: [
                .package(product: "Latchway"),
                .package(product: "LatchwayAppExtensions"),
            ],
            settings: settings(profile: actionProfile, applicationExtension: true)
        ),
    ],
    schemes: [
        .scheme(
            name: "AppAttestConformance",
            shared: true,
            buildAction: .buildAction(targets: [
                "AppAttestConformance",
                "ComponentWidget",
                "ComponentShare",
                "ComponentAction",
            ]),
            runAction: .runAction(
                configuration: .release,
                executable: .executable("AppAttestConformance")
            ),
            archiveAction: .archiveAction(configuration: .release)
        ),
    ]
)
