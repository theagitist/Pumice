// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PumiceCore",
    platforms: [
        .iOS(.v18)
    ],
    products: [
        .library(name: "PumiceCore", targets: ["PumiceCore"])
    ],
    targets: [
        .target(name: "PumiceCore"),
        .testTarget(name: "PumiceCoreTests", dependencies: ["PumiceCore"])
    ],
    swiftLanguageModes: [.v6]
)
