// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Pensieve",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "PensieveKit", targets: ["PensieveKit"]),
  ],
  dependencies: [
    .package(url: "https://github.com/pointfreeco/sqlite-data", from: "1.6.0"),
  ],
  targets: [
    .target(
      name: "PensieveKit",
      dependencies: [.product(name: "SQLiteData", package: "sqlite-data")]
    ),
    .testTarget(
      name: "PensieveKitTests",
      dependencies: ["PensieveKit"],
      resources: [.copy("Fixtures")]
    ),
  ]
)
