// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "LatchwayConsumerSmoke",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    dependencies: [
        .package(name: "Latchway", path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "Consumer",
            dependencies: [
                .product(name: "Latchway", package: "Latchway"),
                .product(name: "LatchwayAppAttest", package: "Latchway"),
                .product(name: "LatchwayAppExtensions", package: "Latchway"),
                .product(name: "LatchwayFirebaseAuth", package: "Latchway"),
                .product(name: "LatchwaySwiftOpenAI", package: "Latchway"),
                .product(name: "LatchwayFoundationModels", package: "Latchway"),
                .product(name: "LatchwayTesting", package: "Latchway"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
