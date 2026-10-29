// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "FishingMacro", platforms: [.macOS(.v14)], products: [
    .executable(name: "FishingMacro", targets: ["FishingMacro"])
], targets: [
    .target(name: "FishingCore"),
    .executableTarget(name: "FishingMacro", dependencies: ["FishingCore"]),
    .executableTarget(name: "CoreChecks", dependencies: ["FishingCore"], path: "Tests/FishingCoreTests")
])
