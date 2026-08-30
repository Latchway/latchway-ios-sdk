// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Latchway",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "Latchway", targets: ["Latchway"]),
        .library(name: "LatchwayAppAttest", targets: ["LatchwayAppAttest"]),
        .library(name: "LatchwayAppExtensions", targets: ["LatchwayAppExtensions"]),
        .library(name: "LatchwayFirebaseAuth", targets: ["LatchwayFirebaseAuth"]),
        .library(name: "LatchwaySwiftOpenAI", targets: ["LatchwaySwiftOpenAI"]),
        .library(name: "LatchwayFoundationModels", targets: ["LatchwayFoundationModels"]),
        .library(name: "LatchwayTesting", targets: ["LatchwayTesting"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/jamesrochabrun/SwiftOpenAI.git",
            exact: "4.6.0"
        ),
    ],
    targets: [
        .target(
            name: "Latchway",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "LatchwayAppAttest",
            dependencies: ["Latchway"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "LatchwayAppExtensions",
            dependencies: ["Latchway"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "LatchwayFirebaseAuth",
            dependencies: ["Latchway"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "LatchwaySwiftOpenAI",
            dependencies: [
                "Latchway",
                .product(name: "SwiftOpenAI", package: "SwiftOpenAI"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "LatchwayFoundationModels",
            dependencies: ["Latchway"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "LatchwayTesting",
            dependencies: ["Latchway"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LatchwayTests",
            dependencies: ["Latchway", "LatchwayTesting"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LatchwayAppAttestTests",
            dependencies: ["Latchway", "LatchwayAppAttest", "LatchwayTesting"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LatchwayAppExtensionsTests",
            dependencies: ["Latchway", "LatchwayAppExtensions", "LatchwayTesting"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LatchwaySwiftOpenAITests",
            dependencies: [
                "Latchway",
                "LatchwaySwiftOpenAI",
                "LatchwayTesting",
                .product(name: "SwiftOpenAI", package: "SwiftOpenAI"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LatchwayFoundationModelsTests",
            dependencies: ["Latchway", "LatchwayFoundationModels", "LatchwayTesting"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ConformanceTests",
            dependencies: ["Latchway", "LatchwayTesting"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
