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
      name: "CSQLiteVec",
      // sqlite-vec.c uses SQLITE_CORE-off extension mode; link the system sqlite3.
      cSettings: [.define("SQLITE_CORE", to: "0")],
      linkerSettings: [.linkedLibrary("sqlite3")]
    ),
    .target(
      name: "PensieveKit",
      dependencies: [
        .product(name: "SQLiteData", package: "sqlite-data"),
        "CSQLiteVec",
      ]
    ),
    .testTarget(
      name: "PensieveKitTests",
      dependencies: ["PensieveKit"],
      resources: [.copy("Fixtures")]
    ),
  ]
)
