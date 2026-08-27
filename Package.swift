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
        .library(name: "LatchwayFirebaseAuth", targets: ["LatchwayFirebaseAuth"]),
        .library(name: "LatchwayTesting", targets: ["LatchwayTesting"]),
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
            name: "LatchwayFirebaseAuth",
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
            name: "ConformanceTests",
            dependencies: ["Latchway", "LatchwayTesting"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
