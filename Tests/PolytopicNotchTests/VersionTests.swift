import Foundation
import Testing
@testable import PolytopicNotch

@Suite("Version")
struct VersionTests {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    @Test("the CHANGELOG's newest entry is this version")
    func changelog() throws {
        let text = try String(contentsOf: root.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
        let newest = text.split(separator: "\n").first { $0.hasPrefix("## ") }
        #expect(newest?.hasPrefix("## \(PolytopicNotchVersion.string)") == true)
    }

    @Test("the wire prefix carries the protocol major")
    func protocolMajor() {
        #expect(NotchDockWire.prefix.hasSuffix(".v\(PolytopicNotchVersion.dockProtocol)"))
    }

    @Test("the public repository names nobody's private hosts, teams or apps")
    func neutral() throws {
        let banned = ["techontires", "MAP28ALWP2", "Tattle", "Live Transcript", "Tech-on-Tires-LLC"]
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }
            .filter { !$0.path.contains("/.build/") && !$0.path.contains("/.git/") && !$0.path.contains("/.swiftpm/") }
            .filter { ["swift", "md", "sh", "yml", "yaml"].contains($0.pathExtension) }
            .filter { $0.lastPathComponent != "VersionTests.swift" }
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for word in banned { #expect(!text.contains(word), "\(file.lastPathComponent) mentions \(word)") }
        }
    }
}
