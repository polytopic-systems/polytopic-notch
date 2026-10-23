import Foundation
import Testing

/// Every Swift code block in README.md and the DocC articles appears, line for line, in a file in this folder, which
/// the test target compiles. So a sample in the docs can't drift from the API: change the API and the snippet stops
/// compiling; change a sample in the docs without the snippet and this test fails.
///
/// How a block is matched: each line is trimmed (indentation doesn't matter, so a statement block can sit inside a
/// function here) and blank lines are dropped, in the block and in the files; the block's lines must then appear as one
/// unbroken run in a single file. A line that is exactly `@main` is dropped too (a test target can't have an entry
/// point). Skipped: blocks whose first line is `// Package.swift` (a manifest, not app code) or starts with
/// `// fragment` (deliberately incomplete; keep those rare).
@Suite("Doc snippets")
struct DocSnippetGuardTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let snippets = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

    struct Block: CustomStringConvertible {
        var file: String
        var line: Int
        var lines: [String]
        var description: String { "\(file):\(line)" }
    }

    static func normalized(_ lines: some Sequence<some StringProtocol>) -> [String] {
        lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0 != "@main" }
    }

    /// The ```swift blocks of a Markdown file.
    static func swiftBlocks(in url: URL) throws -> [Block] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var blocks: [Block] = []
        var current: Block?
        for (index, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if var block = current {
                if line == "```" {
                    blocks.append(block)
                    current = nil
                } else {
                    block.lines.append(raw)
                    current = block
                }
            } else if line == "```swift" {
                current = Block(file: url.lastPathComponent, line: index + 1, lines: [])
            }
        }
        return blocks
    }

    static var documents: [URL] {
        let docc = root.appending(path: "Sources/PolytopicNotch/PolytopicNotch.docc")
        let articles = (try? FileManager.default.contentsOfDirectory(at: docc, includingPropertiesForKeys: nil)) ?? []
        return [root.appending(path: "README.md")] + articles.filter { $0.pathExtension == "md" }.sorted { $0.path < $1.path }
    }

    static func isSkipped(_ block: Block) -> Bool {
        let first = block.lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return first == "// Package.swift" || first.hasPrefix("// fragment")
    }

    static func contains(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return needle.isEmpty }
        return (0...(haystack.count - needle.count)).contains { start in
            haystack[start..<(start + needle.count)].elementsEqual(needle)
        }
    }

    @Test func everySwiftBlockInTheDocsCompiles() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.snippets, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "DocSnippetGuardTests.swift" }
        let compiled = try files.map { Self.normalized(try String(contentsOf: $0, encoding: .utf8).components(separatedBy: "\n")) }
        var checked = 0
        for document in Self.documents {
            for block in try Self.swiftBlocks(in: document) where !Self.isSkipped(block) {
                let lines = Self.normalized(block.lines)
                #expect(compiled.contains { Self.contains($0, lines) },
                        "\(block): this Swift block isn't in Tests/PolytopicNotchTests/DocSnippets (copy it there verbatim, or mark it `// fragment`)")
                checked += 1
            }
        }
        #expect(checked > 20, "the docs lead with code: \(checked) blocks checked")
    }

    @Test func theMatcherIgnoresIndentationAndBlankLinesOnly() {
        let file = Self.normalized(["func f() {", "    let a = 1", "", "    let b = 2", "}"])
        #expect(Self.contains(file, Self.normalized(["let a = 1", "let b = 2"])))
        #expect(!Self.contains(file, Self.normalized(["let a = 1", "let c = 3"])))
        #expect(!Self.contains(file, Self.normalized(["let b = 2", "let a = 1"])))
    }
}
