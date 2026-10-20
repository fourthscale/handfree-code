// swift-tools-version: 5.10
import PackageDescription

let package = Package(
  name: "HandfreeCode",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "0.9.4"),
  ],
  targets: [
    .executableTarget(
      name: "HandfreeCode",
      dependencies: [.product(name: "WhisperKit", package: "WhisperKit")],
      path: "Sources"
    ),
  ]
)
