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
  targets: [
    .target(
      name: "SwiftDataSync",
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
