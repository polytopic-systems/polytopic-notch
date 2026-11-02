// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PolytopicNotch",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "PolytopicNotch", targets: ["PolytopicNotch"]),
    ],
    targets: [
        // NotchLight.metal is copied, not compiled: NotchLightMetal compiles it at runtime, so no Metal toolchain is needed.
        .target(name: "PolytopicNotch", resources: [.copy("Settings/NotchLight.metal")]),
        .testTarget(name: "PolytopicNotchTests", dependencies: ["PolytopicNotch"]),
    ],
    swiftLanguageModes: [.v6]
)
