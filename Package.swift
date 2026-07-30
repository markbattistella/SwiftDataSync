// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SwiftDataSync",
    platforms: [
        .iOS(.v17),
        .macCatalyst(.v17),
        .macOS(.v14),
        .tvOS(.v17),
        .visionOS(.v1),
        .watchOS(.v10),
    ],
    products: [
        .library(
            name: "SwiftDataSync",
            targets: ["SwiftDataSync"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/markbattistella/SimpleLogger", from: "26.0.0")
    ],
    targets: [
        .target(
            name: "SwiftDataSync",
            dependencies: ["SimpleLogger"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "SwiftDataSyncTests",
            dependencies: ["SwiftDataSync"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
