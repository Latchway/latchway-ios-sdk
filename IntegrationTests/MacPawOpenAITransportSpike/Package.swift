// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MacPawOpenAITransportSpike",
    platforms: [.macOS(.v12)],
    dependencies: [
        .package(
            url: "https://github.com/MacPaw/OpenAI.git",
            exact: "0.5.1"
        ),
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
