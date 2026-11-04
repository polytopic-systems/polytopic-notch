// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PolytopicNotch",
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "PolytopicNotch", targets: ["PolytopicNotch"]),
    ],
    targets: [
        // NotchLight.metal is copied, not compiled: NotchLightMetal compiles it at runtime, so no Metal toolchain is needed.
        // Resources/Localizable.xcstrings holds the package's own words in every language (Docs/Localization.md).
        .target(name: "PolytopicNotch", resources: [.copy("Settings/NotchLight.metal"), .process("Resources")]),
        .testTarget(name: "PolytopicNotchTests", dependencies: ["PolytopicNotch"]),
    ],
    swiftLanguageModes: [.v6]
)
