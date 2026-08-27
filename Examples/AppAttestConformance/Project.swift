import ProjectDescription

let bundleID = Environment.latchwayConformanceBundleID.getString(
    default: "dev.latchway.conformance"
)
let developmentTeam = Environment.latchwayDevelopmentTeam.getString(default: "")
let appAttestEnvironment = Environment.latchwayAppAttestEnvironment.getString(
    default: "development"
)

guard ["development", "production"].contains(appAttestEnvironment) else {
    fatalError(
        "TUIST_LATCHWAY_APP_ATTEST_ENVIRONMENT must be development or production"
    )
}

var buildSettings: SettingsDictionary = [
    "CODE_SIGN_STYLE": "Automatic",
    "SWIFT_STRICT_CONCURRENCY": "complete",
    "SWIFT_VERSION": "6.0",
]
if !developmentTeam.isEmpty {
    buildSettings["DEVELOPMENT_TEAM"] = .string(developmentTeam)
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
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "Latchway Conformance",
                "UILaunchScreen": [:],
            ]),
            sources: ["Sources/**"],
            entitlements: .file(
                path: "AppAttestConformance.\(appAttestEnvironment).entitlements"
            ),
            dependencies: [
                .package(product: "Latchway"),
                .package(product: "LatchwayAppAttest"),
            ],
            settings: .settings(base: buildSettings)
        ),
    ],
    schemes: [
        .scheme(
            name: "AppAttestConformance",
            shared: true,
            buildAction: .buildAction(targets: ["AppAttestConformance"]),
            runAction: .runAction(
                configuration: .debug,
                executable: .executable("AppAttestConformance")
            )
        ),
    ]
)
