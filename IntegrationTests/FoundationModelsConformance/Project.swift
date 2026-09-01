import ProjectDescription

let project = Project(
    name: "FoundationModelsConformance",
    options: .options(automaticSchemesOptions: .disabled),
    packages: [
        .local(path: "../.."),
    ],
    targets: [
        .target(
            name: "FoundationModelsConformanceTests",
            destinations: .iOS,
            product: .unitTests,
            bundleId: "dev.latchway.foundation-models-conformance-tests",
            deploymentTargets: .iOS("27.0"),
            infoPlist: .default,
            sources: ["../../Tests/LatchwayFoundationModelsTests/**"],
            dependencies: [
                .package(product: "Latchway"),
                .package(product: "LatchwayFoundationModels"),
            ],
            settings: .settings(base: [
                "SWIFT_STRICT_CONCURRENCY": "complete",
                "SWIFT_VERSION": "6.0",
            ])
        ),
    ],
    schemes: [
        .scheme(
            name: "FoundationModelsConformance",
            shared: true,
            buildAction: .buildAction(targets: ["FoundationModelsConformanceTests"]),
            testAction: .targets(
                ["FoundationModelsConformanceTests"],
                configuration: .debug
            )
        ),
    ]
)
