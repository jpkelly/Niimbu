// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NiimbotKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "NiimbotKit", targets: ["NiimbotKit"]),
    ],
    targets: [
        .target(name: "NiimbotKit"),
        .testTarget(name: "NiimbotKitTests", dependencies: ["NiimbotKit"]),
    ],
    swiftLanguageModes: [.v5]
)
