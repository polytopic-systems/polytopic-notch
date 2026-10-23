// Stand-ins for other notch apps and menu bar managers, for checking the notch-neighbor handling
// on a Mac that doesn't have them. Each puts up a transparent panel shaped like the real app's (size,
// level, position, a tracking area, the same mouse behaviour), drawing only a small notch-sized shape the
// way the real apps do while idle.
//
// Build the app bundles (each needs the real app's bundle ID to be recognised by name). They go into a
// folder outside Dropbox (Dropbox's extended attributes break code signing):
//     Tools/notch-standins.sh [<output folder>]        # default ~/Library/Caches/notch-standins
// then launch one with `open -n <folder>/<profile>.app`, or let the package's live test do it:
//     NOTCH_STANDINS_DIR=<folder> swift test --scratch-path ~/Library/Caches/polytopic-notch-build --filter NotchStandInLiveTests
// Each stand-in writes what it does to <folder>/<profile>.log. Afterwards
// `Tools/notch-standins.sh --unregister <folder>` removes them from Launch Services.

import AppKit

struct Profile {
    enum Frame {
        /// Centred on the notch (or the top of the screen), hanging from the top edge.
        case topCentre(width: CGFloat, height: CGFloat)
        /// The full width of the screen, hanging from the top edge.
        case fullWidth(height: CGFloat)
        /// Half the screen each way, top-centre (DynamicNotchKit).
        case halfScreen
        /// Just under the menu bar, centred (a popover from a menu bar extra).
        case underMenuBar(width: CGFloat, height: CGFloat)
    }
    enum Behaviour {
        case steady
        /// Shows for `on` seconds, hides for `off`, repeatedly (an event-driven island).
        case blinking(on: Double, off: Double)
        /// Alternates between its idle size and an open size (Atoll's window follows its content).
        case resizing(open: CGSize, every: Double)
        /// Ice: a full-width click-through tint plus a bar under the menu bar that opens and closes.
        case iceBar(every: Double)
    }

    var frame: Frame
    var level: Int
    var behaviour: Behaviour = .steady
    /// `true`: sets `ignoresMouseEvents = false` explicitly, so the whole transparent box catches clicks
    /// (the worst case). `false`: AppKit's default, where transparent areas let clicks through.
    var catchesClicks = false
}

let profiles: [String: Profile] = [
    "boring": Profile(frame: .topCentre(width: 640, height: 210), level: 27, catchesClicks: true),
    "atoll": Profile(frame: .topCentre(width: 300, height: 38), level: 27,
                     behaviour: .resizing(open: CGSize(width: 500, height: 190), every: 2)),
    "notchdrop": Profile(frame: .fullWidth(height: 200), level: 33),
    "notchi": Profile(frame: .fullWidth(height: 120), level: 27),
    "dnk": Profile(frame: .halfScreen, level: 1_000),
    "island": Profile(frame: .topCentre(width: 300, height: 80), level: 26, behaviour: .blinking(on: 1.5, off: 3)),
    "generic": Profile(frame: .topCentre(width: 360, height: 90), level: 27),
    "wide": Profile(frame: .fullWidth(height: 200), level: 27),
    "popover": Profile(frame: .underMenuBar(width: 320, height: 400), level: 101),
    "ice": Profile(frame: .fullWidth(height: 0), level: 25, behaviour: .iceBar(every: 1.5)),
]

let arguments = CommandLine.arguments
// The profile is the first argument, or the bundle's name (boring.app → boring) when opened from Finder or `open`.
let name = arguments.dropFirst().first { profiles[$0] != nil }
    ?? Bundle.main.bundleURL.deletingPathExtension().lastPathComponent
guard var profile = profiles[name] else {
    FileHandle.standardError.write("usage: standin <\(profiles.keys.sorted().joined(separator: "|"))> [--catch-clicks] [--pass-clicks] [--log <file>]\n".data(using: .utf8)!)
    exit(2)
}
if arguments.contains("--catch-clicks") { profile.catchesClicks = true }
if arguments.contains("--pass-clicks") { profile.catchesClicks = false }
let logURL: URL? = arguments.firstIndex(of: "--log").flatMap { $0 + 1 < arguments.count ? URL(fileURLWithPath: arguments[$0 + 1]) : nil }
    ?? Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("\(name).log")

func log(_ line: String) {
    let text = "\(Date().timeIntervalSince1970) \(name) pid \(getpid()): \(line)\n"
    FileHandle.standardOutput.write(text.data(using: .utf8)!)
    guard let logURL else { return }
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(text.data(using: .utf8)!)
        try? handle.close()
    } else {
        try? text.write(to: logURL, atomically: true, encoding: .utf8)
    }
}

/// Draws a black notch-sized shape at the top centre and logs pointer activity over it.
final class ShapeView: NSView {
    var shape: CGRect = .zero { didSet { needsDisplay = true; updateTrackingAreas() } }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        NSBezierPath(roundedRect: shape, xRadius: 10, yRadius: 10).fill()
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: shape, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { log("pointer entered its shape") }
    override func mouseExited(with event: NSEvent) { log("pointer left its shape") }
    override func mouseDown(with event: NSEvent) { log("mouse down at \(NSEvent.mouseLocation)") }
}

final class StandIn: NSObject, NSApplicationDelegate {
    let profile: Profile
    var panels: [NSPanel] = []
    var timer: Timer?

    init(profile: Profile) { self.profile = profile }

    var screen: NSScreen { NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0] }
    var menuBarHeight: CGFloat { screen.frame.maxY - screen.visibleFrame.maxY }
    var notchHeight: CGFloat { max(screen.safeAreaInsets.top, menuBarHeight) }

    func frame(for frame: Profile.Frame) -> CGRect {
        let s = screen.frame
        switch frame {
        case .topCentre(let width, let height):
            return CGRect(x: s.midX - width / 2, y: s.maxY - height, width: width, height: height)
        case .fullWidth(let height):
            return CGRect(x: s.minX, y: s.maxY - height, width: s.width, height: height)
        case .halfScreen:
            return CGRect(x: s.midX - s.width / 4, y: s.maxY - s.height / 2, width: s.width / 2, height: s.height / 2)
        case .underMenuBar(let width, let height):
            return CGRect(x: s.midX - width / 2, y: s.maxY - menuBarHeight - 2 - height, width: width, height: height)
        }
    }

    func makePanel(_ rect: CGRect, level: Int, catchesClicks: Bool, drawsShape: Bool = true) -> NSPanel {
        let panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: level)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        if catchesClicks { panel.ignoresMouseEvents = false }
        let view = ShapeView(frame: CGRect(origin: .zero, size: rect.size))
        view.autoresizingMask = [.width, .height]
        if drawsShape { view.shape = idleShape(in: rect) }
        panel.contentView = view
        return panel
    }

    /// The visible part while idle: notch-sized, at the top centre of the panel.
    func idleShape(in rect: CGRect) -> CGRect {
        let width = min(rect.width, 230)
        let height = min(rect.height, notchHeight)
        return CGRect(x: screen.frame.midX - rect.minX - width / 2, y: rect.height - height, width: width, height: height)
    }

    func show(_ panel: NSPanel) {
        panel.orderFrontRegardless()
        log("window \(panel.windowNumber) level \(panel.level.rawValue) frame \(NSStringFromRect(panel.frame)) "
            + "catches clicks \(profile.catchesClicks)")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        switch profile.behaviour {
        case .steady:
            let panel = makePanel(frame(for: profile.frame), level: profile.level, catchesClicks: profile.catchesClicks)
            panels = [panel]
            show(panel)
        case .blinking(let on, let off):
            let panel = makePanel(frame(for: profile.frame), level: profile.level, catchesClicks: profile.catchesClicks)
            panels = [panel]
            func cycle() {
                show(panel)
                DispatchQueue.main.asyncAfter(deadline: .now() + on) {
                    panel.orderOut(nil)
                    log("hidden")
                    DispatchQueue.main.asyncAfter(deadline: .now() + off) { cycle() }
                }
            }
            cycle()
        case .resizing(let open, let every):
            let idle = frame(for: profile.frame)
            let panel = makePanel(idle, level: profile.level, catchesClicks: profile.catchesClicks)
            panels = [panel]
            show(panel)
            var isOpen = false
            timer = Timer.scheduledTimer(withTimeInterval: every, repeats: true) { [unowned self] _ in
                isOpen.toggle()
                let rect = isOpen ? self.frame(for: .topCentre(width: open.width, height: open.height)) : idle
                panel.setFrame(rect, display: true)
                (panel.contentView as? ShapeView)?.shape = isOpen ? CGRect(origin: .zero, size: rect.size) : self.idleShape(in: rect)
                log("resized to \(NSStringFromRect(rect))")
            }
        case .iceBar(let every):
            let s = screen.frame
            let tint = makePanel(CGRect(x: s.minX, y: s.maxY - menuBarHeight - 5, width: s.width, height: menuBarHeight + 5),
                                 level: profile.level, catchesClicks: false, drawsShape: false)
            tint.ignoresMouseEvents = true
            let barRect = CGRect(x: s.midX + 60, y: s.maxY - menuBarHeight - 30, width: 420, height: 30)
            let bar = makePanel(barRect, level: profile.level, catchesClicks: true, drawsShape: false)
            (bar.contentView as? ShapeView)?.shape = CGRect(origin: .zero, size: barRect.size)
            panels = [tint, bar]
            show(tint)
            var open = false
            timer = Timer.scheduledTimer(withTimeInterval: every, repeats: true) { [unowned self] _ in
                open.toggle()
                if open { self.show(bar) } else { bar.orderOut(nil); log("bar hidden") }
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = StandIn(profile: profile)
app.delegate = delegate
signal(SIGTERM) { _ in exit(0) }
log("started as \(Bundle.main.bundleIdentifier ?? "no bundle ID")")
app.run()
