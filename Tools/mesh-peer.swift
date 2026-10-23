// A stand-in docked app for checking the dock live on this Mac, without a real notch app: an agent app that
// docks through PolytopicNotch (the real panel controller, dock, distributed-notification channel and code-signature
// trust) and draws a coloured slot from a scripted list of wants. No microphone, no sound, no network.
//
// Build and run it with the script (it signs the bundles with an Apple Development identity when this Mac has one,
// else ad hoc for DEBUG, and refuses cloud-synced output folders):
//     Tools/mesh-peer.sh build [<folder>]                     # default ~/Library/Caches/polytopic-mesh-peer
//     Tools/mesh-peer.sh run --style split --seconds 8        # two peers (red, blue) side by side, then quits them
// Each peer logs what the dock gave it to <folder>/<name>.log.
//
// Arguments: --name <red|blue|green…> --script "quiet:2,live:3,urgent:3,notice:2,none:1" (want:seconds, repeated)
//            --style <priority|switcher|split|merged> (writes the stand-ins' shared settings) --seconds <n>
//            --log <file> --suite <defaults suite> (default systems.polytopic.notch.meshpeer, not the apps' own)
//            --sharing <never|automatic> (default never: real notch apps on this Mac don't move the stand-ins)

import AppKit
import PolytopicNotch
import SwiftUI

struct Options {
    var name = "red"
    var script: [(want: NotchWant, seconds: Double)] = [(.quiet, 2), (.live, 3), (.notice, 2)]
    var style: NotchSharingStyle?
    var seconds: Double = 10
    var log = "/dev/stdout"
    var suite = "systems.polytopic.notch.meshpeer"
    var sharing: NotchSharing = .never

    init(_ arguments: [String]) {
        var it = arguments.dropFirst().makeIterator()
        while let key = it.next() {
            let value = it.next() ?? ""
            switch key {
            case "--name": name = value
            case "--script":
                script = value.split(separator: ",").compactMap { step in
                    let parts = step.split(separator: ":")
                    guard parts.count == 2, let seconds = Double(parts[1]) else { return nil }
                    return (NotchWant(name: String(parts[0])), seconds)
                }
            case "--style": style = NotchSharingStyle(rawValue: value)
            case "--seconds": seconds = Double(value) ?? 10
            case "--log": log = value
            case "--suite": suite = value
            case "--sharing": sharing = NotchSharing(rawValue: value) ?? .never
            default: break
            }
        }
    }

    var color: Color {
        switch name {
        case "blue": .blue
        case "green": .green
        case "orange": .orange
        case "pink": .pink
        default: .red
        }
    }
}

final class LogFile: @unchecked Sendable {
    private let handle: FileHandle?
    private let start = Date()
    private let lock = NSLock()

    init(path: String) {
        if path != "/dev/stdout" { FileManager.default.createFile(atPath: path, contents: nil) }
        handle = FileHandle(forWritingAtPath: path)
    }

    func write(_ line: String) {
        let text = String(format: "%7.3f ", Date().timeIntervalSince(start)) + line + "\n"
        lock.withLock { handle?.write(Data(text.utf8)) }
    }
}

@MainActor
final class Peer: NSObject, NSApplicationDelegate {
    let options = Options(CommandLine.arguments)
    lazy var file = LogFile(path: options.log)
    let content = NotchContent()
    var dock: NotchDock!
    var controller: NotchPanelController!
    var prompts: NotchPromptWindowController!
    var monitor: NotchNeighborMonitor!
    var lastLine = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        let appID = Bundle.main.bundleIdentifier ?? "com.example.meshpeer.\(options.name)"
        let log = NotchLog { [file] level, message in file.write("[\(level.rawValue)] \(message)") }
        var trust = DeveloperIDTrust()
        #if DEBUG
        // An ad-hoc signed stand-in (no Apple Development identity on this Mac) admits its ad-hoc peers.
        trust.allowAdHocForTesting = Bundle.main.object(forInfoDictionaryKey: "MeshPeerAdHoc") as? Bool == true
        #endif
        let symbol = ["red": "r.circle.fill", "blue": "b.circle.fill", "green": "g.circle.fill"][options.name] ?? "circle.fill"
        dock = NotchDock(appID: appID, symbol: symbol, trust: trust,
                         settings: NotchDockSettings(storage: UserDefaults(suiteName: options.suite)), log: log)
        if let style = options.style { dock.setStyle(style) }
        monitor = NotchNeighborMonitor(log: log, ownBundleID: appID)
        content.symbol = symbol
        content.title = "Stand-in \(options.name)"
        let color = options.color
        let name = options.name
        content.showing = NotchBody(height: 46) { StandInBody(text: "\(name): showing", color: color) }
        content.expanded = NotchBody(height: 120) { StandInBody(text: "\(name): open (hovered)", color: color) }
        controller = NotchPanelController(content: content, settings: InMemoryNotchSettings(NotchSettings(sharing: options.sharing)),
                                          neighbors: monitor, log: log, dock: dock)
        prompts = NotchPromptWindowController(content: content) { [weak self] in self?.controller.pillShowsPrompt ?? false }
        controller.start()
        file.write("START \(appID) pid \(getpid()) adhoc \(Bundle.main.object(forInfoDictionaryKey: "MeshPeerAdHoc") as? Bool == true) style \(dock.style.rawValue)")
        watch()
        Task { await runScript() }
        DispatchQueue.main.asyncAfter(deadline: .now() + options.seconds) { [weak self] in
            MainActor.assumeIsolated {
                self?.file.write("QUIT")
                self?.controller.stop()
                NSApp.terminate(nil)
            }
        }
    }

    func runScript() async {
        while true {
            for step in options.script {
                apply(step.want)
                try? await Task.sleep(for: .seconds(step.seconds))
            }
        }
    }

    func apply(_ want: NotchWant) {
        content.want = want
        switch want {
        case .none: content.status = .off; content.prompt = nil
        case .quiet: content.status = .quiet; content.prompt = nil
        case .notice, .live: content.status = .showing; content.prompt = nil; content.level = want == .live ? 0.7 : 0.3
        case .urgent:
            content.status = .attention
            let color = options.color, name = options.name
            content.prompt = NotchBody(height: 70) { StandInBody(text: "\(name): a question (urgent)", color: color) }
        }
        file.write("WANT \(want.name)")
    }

    /// Logs what the dock gives this app whenever it changes, and keeps the floating question window right.
    func watch() {
        let line = withObservationTracking { () -> String in
            let slot = controller.viewModel.slot
            let peers = dock.peers.values.map { "\($0.appID.split(separator: ".").last ?? "")=\($0.want.name)/\($0.mode.name)" }.sorted()
            let frame = slot.frame.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "-"
            prompts.update()
            return "SLOT \(slot.role.rawValue) \(frame) level \(controller.panelLevel.rawValue) mode \(controller.viewModel.mode.name) "
                + "mayAsk \(slot.mayAsk) floating \(prompts.isShowing) style \(dock.style.rawValue) peers [\(peers.joined(separator: " "))]"
        } onChange: { [weak self] in
            Task { @MainActor in self?.watch() }
        }
        if line != lastLine {
            lastLine = line
            file.write(line)
        }
    }
}

struct StandInBody: View {
    var text: String
    var color: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(text).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(color.opacity(0.35))
    }
}

@main
struct MeshPeerMain {
    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let peer = Peer()
            app.delegate = peer
            withExtendedLifetime(peer) { app.run() }
        }
    }
}
