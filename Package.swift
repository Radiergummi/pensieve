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
      dependencies: [
        .product(name: "SQLiteData", package: "sqlite-data"),
      ],
      // Documentation that lives next to the code it describes; not a build input.
      exclude: ["Eval/README.md"]
    ),
    .testTarget(
      name: "PensieveKitTests",
      dependencies: ["PensieveKit"],
      resources: [.copy("Fixtures")]
    ),
  ]
)
