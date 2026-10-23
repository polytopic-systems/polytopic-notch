// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NotchDemo",
    platforms: [.macOS("26.0")],
    dependencies: [.package(name: "PolytopicNotch", path: "../..")],
    targets: [
        .executableTarget(name: "NotchDemo", dependencies: [.product(name: "PolytopicNotch", package: "PolytopicNotch")]),
    ],
    swiftLanguageModes: [.v6]
)
