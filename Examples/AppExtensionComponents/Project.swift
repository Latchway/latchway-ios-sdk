import ProjectDescription

let hostBundleID = Environment.latchwayComponentHostBundleID.getString(
    default: "dev.latchway.component-example"
)
let componentGroupSuffix = Environment.latchwayComponentGroupSuffix.getString(
    default: "dev.latchway.component-example.widget"
)
let developmentTeam = Environment.latchwayDevelopmentTeam.getString(default: "")
let gatewayURL = Environment.latchwayGatewayURL.getString(
    default: "https://gateway.example.invalid"
)
let applicationID = Environment.latchwayApplicationID.getString(
    default: "app_00000000000000000000000000"
)
let environment = Environment.latchwayEnvironment.getString(default: "development")
let identityProvider = Environment.latchwayIdentityProvider.getString(default: "firebase")
let rootAccessGroup = "$(AppIdentifierPrefix)\(hostBundleID)"
let accessGroup = "$(AppIdentifierPrefix)\(componentGroupSuffix)"

var settings: SettingsDictionary = [
    "CODE_SIGN_STYLE": "Automatic",
    "SWIFT_STRICT_CONCURRENCY": "complete",
    "SWIFT_VERSION": "6.0",
]
if !developmentTeam.isEmpty {
    settings["DEVELOPMENT_TEAM"] = .string(developmentTeam)
}

let commonInfo: [String: Plist.Value] = [
    "LatchwayApplicationID": .string(applicationID),
    "LatchwayEnvironment": .string(environment),
    "LatchwayIdentityProvider": .string(identityProvider),
    "LatchwayGatewayURL": .string(gatewayURL),
    "LatchwayRootKeychainAccessGroup": .string(rootAccessGroup),
    "LatchwayHostComponentDefinitionID": "host_app",
    "LatchwayWidgetComponentDefinitionID": "home_widget",
    "LatchwayWidgetFeature": "weekly-summary",
    "LatchwayWidgetKeychainAccessGroup": .string(accessGroup),
]

let project = Project(
    name: "AppExtensionComponents",
    options: .options(automaticSchemesOptions: .disabled),
    packages: [.local(path: "../..")],
    targets: [
        .target(
            name: "ComponentHost",
            destinations: .iOS,
            product: .app,
            bundleId: hostBundleID,
            deploymentTargets: .iOS("15.0"),
            infoPlist: .extendingDefault(with: commonInfo.merging([
                "CFBundleDisplayName": "Latchway Components",
                "UILaunchScreen": [:],
            ]) { _, new in new }),
            sources: ["Host/**", "Shared/**"],
            entitlements: .dictionary([
                "com.apple.developer.devicecheck.appattest-environment": "development",
                "keychain-access-groups": [
                    .string(rootAccessGroup),
                    .string(accessGroup),
                ],
            ]),
            dependencies: [
                .target(name: "ComponentWidget"),
                .package(product: "Latchway"),
                .package(product: "LatchwayAppAttest"),
                .package(product: "LatchwayAppExtensions"),
            ],
            settings: .settings(base: settings)
        ),
        .target(
            name: "ComponentWidget",
            destinations: .iOS,
            product: .appExtension,
            bundleId: "\(hostBundleID).widget",
            deploymentTargets: .iOS("15.0"),
            infoPlist: .extendingDefault(with: commonInfo.merging([
                "CFBundleDisplayName": "Latchway Component Widget",
                "NSExtension": [
                    "NSExtensionPointIdentifier": "com.apple.widgetkit-extension",
                ],
            ]) { _, new in new }),
            sources: ["Widget/**", "Shared/**"],
            entitlements: .dictionary([
                "keychain-access-groups": [.string(accessGroup)],
            ]),
            dependencies: [
                .package(product: "Latchway"),
                .package(product: "LatchwayAppExtensions"),
            ],
            settings: .settings(base: settings)
        ),
    ],
    schemes: [
        .scheme(
            name: "AppExtensionComponents",
            shared: true,
            buildAction: .buildAction(targets: ["ComponentHost", "ComponentWidget"]),
            runAction: .runAction(executable: .executable("ComponentHost"))
        ),
    ]
)
