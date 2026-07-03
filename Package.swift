// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Pensieve",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "PensieveKit", targets: ["PensieveKit"]),
    .executable(name: "pensieve", targets: ["pensieve"]),
  ],
  dependencies: [
    .package(url: "https://github.com/pointfreeco/sqlite-data", from: "1.6.0"),
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
  ],
  targets: [
    .target(
      name: "PensieveKit",
      dependencies: [.product(name: "SQLiteData", package: "sqlite-data")]
    ),
    .executableTarget(
      name: "pensieve",
      dependencies: [
        "PensieveKit",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
    .testTarget(name: "PensieveKitTests", dependencies: ["PensieveKit"]),
  ]
)
