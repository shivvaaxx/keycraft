// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KeycraftCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "KeycraftCore", targets: ["KeycraftCore"])],
    targets: [
        .target(name: "KeycraftCore", resources: [.copy("Resources/KeyboardDatabase")]),
        .testTarget(name: "KeycraftCoreTests", dependencies: ["KeycraftCore"], resources: [.copy("Fixtures")]),
    ]
)
