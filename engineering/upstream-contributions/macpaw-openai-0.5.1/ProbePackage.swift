// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MacPawOpenAITransportProbe",
    platforms: [.macOS(.v12)],
    dependencies: [
        .package(path: "../OpenAI"),
    ],
    targets: [
        .executableTarget(
            name: "MacPawOpenAITransportSpike",
            dependencies: [
                .product(name: "OpenAI", package: "OpenAI"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
