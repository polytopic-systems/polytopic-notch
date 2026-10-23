// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PolytopicNotch",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "PolytopicNotch", targets: ["PolytopicNotch"]),
    ],
    targets: [
        .target(name: "PolytopicNotch"),
        .testTarget(name: "PolytopicNotchTests", dependencies: ["PolytopicNotch"]),
    ],
    swiftLanguageModes: [.v6]
)
