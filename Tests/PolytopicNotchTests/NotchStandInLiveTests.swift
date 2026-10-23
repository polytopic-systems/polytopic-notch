import AppKit
import Testing
@testable import PolytopicNotch

/// Checks the notch-neighbor handling against real windows on this Mac.
///
/// The stand-in test needs the stand-in apps from `Tools/notch-standins.sh` and only runs when asked (it puts
/// windows over the notch for about a minute: run it on purpose):
///     Tools/notch-standins.sh ~/Library/Caches/notch-standins
///     NOTCH_STANDINS_DIR=~/Library/Caches/notch-standins swift test --scratch-path ~/Library/Caches/polytopic-notch-build \
///         --filter NotchStandInLiveTests
/// It reads state from the monitor and the panel controller, and asks the window server which window a
/// click would land in (`NSWindow.windowNumber(at:belowWindowWithWindowNumber:)` honours transparency and
/// `ignoresMouseEvents`). Pointer movement is fed to the controller directly; the real pointer is untouched.
@MainActor
@Suite(.serialized)
struct NotchStandInLiveTests {
    nonisolated static let folder = ProcessInfo.processInfo.environment["NOTCH_STANDINS_DIR"]
        .map { ($0 as NSString).expandingTildeInPath }
    nonisolated static let bartenderRunning = NSWorkspace.shared.runningApplications.contains {
        $0.bundleIdentifier?.hasPrefix("com.surteesstudios.Bartender") == true
    }
    /// With the lid closed or only an external display, there's no notch to share: the pill sits in the menu bar.
    nonisolated static let notchScreen = NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }

    // MARK: - Helpers

    func note(_ line: String) {
        print("LIVE: \(line)")
        guard let folder = Self.folder else { return }
        let url = URL(fileURLWithPath: folder).appendingPathComponent("results.txt")
        let text = line + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Launches a stand-in and returns its PID once it's registered.
    func launch(_ profile: String, _ extra: [String] = []) async throws -> pid_t {
        let folder = try #require(Self.folder)
        let app = URL(fileURLWithPath: folder).appendingPathComponent("\(profile).app")
        let before = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-n", "-g", app.path, "--args", profile] + extra
        try open.run()
        open.waitUntilExit()
        var pid: pid_t?
        _ = await wait(timeout: 5) {
            pid = NSWorkspace.shared.runningApplications.first {
                $0.bundleURL?.standardizedFileURL == app.standardizedFileURL && !before.contains($0.processIdentifier)
            }?.processIdentifier
            return pid != nil
        }
        return try #require(pid, "stand-in \(profile) didn't start")
    }

    func quit(_ pid: pid_t) { kill(pid, SIGTERM) }

    func quitAllStandIns() {
        guard let folder = Self.folder else { return }
        for app in NSWorkspace.shared.runningApplications where app.bundleURL?.path.hasPrefix(folder) == true {
            kill(app.processIdentifier, SIGTERM)
        }
    }

    /// Seconds until `condition` held, or nil on timeout.
    func wait(timeout: Double = 6, _ condition: () -> Bool) async -> Double? {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if condition() { return Date().timeIntervalSince(start) }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition() ? timeout : nil
    }

    struct Hit: CustomStringConvertible {
        var number: Int
        var pid: pid_t?
        var owner: String
        var layer: Int?
        var description: String { "\(owner) (window \(number), layer \(layer.map(String.init) ?? "?"))" }
    }

    /// The window a click at this point (AppKit screen coordinates) would go to.
    func hit(_ point: NSPoint) -> Hit {
        let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)) as? [[String: Any]])?.first
        return Hit(number: number, pid: info?[kCGWindowOwnerPID as String] as? pid_t,
                   owner: info?[kCGWindowOwnerName as String] as? String ?? "?", layer: info?[kCGWindowLayer as String] as? Int)
    }

    func makeController(ignoring: [NotchIgnoredApp]) throws -> (NotchPanelController, NotchNeighborMonitor, InMemoryNotchSettings) {
        let settings = InMemoryNotchSettings(NotchSettings(ignoredApps: ignoring))
        let monitor = NotchNeighborMonitor()
        let controller = NotchPanelController(content: NotchContent(), settings: settings, neighbors: monitor)
        controller.followsRealPointer = false
        controller.start()
        // These tests watch where the pill would go while nothing is showing, so keep the close watch
        // the visible pill would get (hidden, it relaxes to the slow sweep).
        monitor.setAttentive(true, for: "test")
        return (controller, monitor, settings)
    }

    static let bartender = NotchIgnoredApp(bundleID: "com.surteesstudios.Bartender", name: "Bartender")

    // MARK: - Stand-ins

    @Test(.enabled(if: folder != nil, "set NOTCH_STANDINS_DIR to a folder made by Tools/notch-standins.sh"),
          .enabled(if: notchScreen, "no display with a notch"))
    func standInsMoveThePillAndClicksStillReachIt() async throws {
        quitAllStandIns()
        defer { quitAllStandIns() }
        // The real Bartender 7 on this Mac would already hold the notch; set it aside so each stand-in's
        // effect shows on its own (this also exercises "don't make room").
        let (controller, monitor, _) = try makeController(ignoring: [Self.bartender])
        let model = controller.viewModel
        note("start: placement \(model.placement) · detected \(monitor.detected.map(\.name)) · neighbors \(monitor.neighbors.map(\.name)) · pace \(monitor.pace)")
        #expect(await wait { model.placement == .notch } != nil, "no neighbor should be present at the start")

        // 1. Boring Notch: fixed 640×210 box at level 27 that catches every click inside it.
        let boring = try await launch("boring")
        let boringLatency = await wait { model.placement == .belowNotch }
        note("Boring Notch stand-in launched → below the notch after \(boringLatency.map { String(format: "%.2f s", $0) } ?? "never")"
             + " · neighbors \(monitor.neighbors.map(\.name)) · panel level \(controller.panelLevel.rawValue)")
        #expect(boringLatency != nil)
        #expect(monitor.neighbors.map(\.name) == ["Boring Notch"])
        #expect(controller.panelLevel == .statusBar)

        let notch = model.geometry.notchRect
        let notchCenter = NSPoint(x: notch.midX, y: notch.midY)
        let pill = model.geometry.pillRect(size: model.size(for: .expanded))
        let pillCenter = NSPoint(x: pill.midX, y: pill.midY)
        note("idle: a click at the pill's spot goes to \(hit(pillCenter)); at the notch to \(hit(notchCenter))")
        #expect(hit(pillCenter).pid == boring, "while we're idle the click-catching box owns the area")
        #expect(hit(notchCenter).pid == boring)

        // Hover the notch: ours opens, rises above the neighbor, and takes clicks on the pill.
        controller.pointerMoved(to: notchCenter, option: false)
        #expect(await wait { model.isHovering } != nil)
        controller.pointerMoved(to: pillCenter, option: false)
        let ours = await wait(timeout: 2) { hit(pillCenter).number == controller.panelWindowNumber }
        note("hovering: level \(controller.panelLevel.rawValue) · a click on the pill goes to \(hit(pillCenter))"
             + " (ours after \(ours.map { String(format: "%.2f s", $0) } ?? "never"))")
        #expect(controller.panelLevel == NotchPanel.hoverLevel)
        #expect(ours != nil, "clicks on our open pill must reach us even under a click-catching neighbor")

        // Leave: ours closes, drops back, and doesn't block the neighbor.
        controller.pointerMoved(to: NSPoint(x: notch.midX, y: 200), option: false)
        #expect(await wait { !model.isHovering } != nil)
        _ = await wait(timeout: 2) { hit(pillCenter).pid == boring }
        note("left: level \(controller.panelLevel.rawValue) · pill spot → \(hit(pillCenter)) · notch → \(hit(notchCenter))")
        #expect(controller.panelLevel == .statusBar)
        #expect(hit(pillCenter).pid == boring && hit(notchCenter).pid == boring)

        // Option on the notch leaves it to the neighbor until the pointer moves away.
        controller.pointerMoved(to: notchCenter, option: true)
        #expect(model.isYielding && model.mode == .hidden)
        controller.pointerMoved(to: NSPoint(x: notch.midX, y: 300), option: false)
        #expect(!model.isYielding)
        note("Option-hover on the notch → yielding; pointer away → back")

        quit(boring)
        let backLatency = await wait { model.placement == .notch }
        note("Boring Notch stand-in quit → back on the notch after \(backLatency.map { String(format: "%.2f s", $0) } ?? "never")")
        #expect(backLatency != nil)

        // 2. An unknown event-driven island: shows 1.5 s, hides 3 s. Counts after a second look, then sticks.
        let island = try await launch("island")
        let islandLatency = await wait(timeout: 8) { model.placement == .belowNotch }
        note("unknown island appeared → below the notch after \(islandLatency.map { String(format: "%.2f s", $0) } ?? "never")"
             + " · neighbors \(monitor.neighbors.map { "\($0.name) [\($0.profileName ?? "general rule")]" })")
        #expect(islandLatency != nil)
        try await Task.sleep(for: .seconds(2.5))
        let islandWindows = NotchNeighborMonitor.onScreenWindows().filter { $0.ownerPID == island }
        note("island hidden (on-screen windows: \(islandWindows.count)) → placement still \(model.placement)")
        #expect(islandWindows.isEmpty)
        #expect(model.placement == .belowNotch, "the pill mustn't hop when the island blinks off")
        quit(island)
        #expect(await wait { model.placement == .notch } != nil)
        note("island quit → back on the notch")

        // 3. A crowd: strips, a half-screen level-1000 panel, a resizing island, plus things that must not count.
        var crowd: [String: pid_t] = [:]
        for profile in ["notchdrop", "notchi", "dnk", "atoll", "generic", "wide", "popover", "ice"] {
            crowd[profile] = try await launch(profile)
        }
        let expected: Set = ["NotchDrop", "Notchi", "DynamicNotch stand-in", "Atoll", "Generic Notch stand-in"]
        let crowdLatency = await wait(timeout: 8) { Set(monitor.neighbors.map(\.name)) == expected }
        note("crowd: neighbors \(monitor.neighbors.map(\.name).sorted()) after \(crowdLatency.map { String(format: "%.2f s", $0) } ?? "never")")
        #expect(Set(monitor.neighbors.map(\.name)) == expected, "wide strip, popover and Ice must not count")
        let dropped = await wait(timeout: 5) { model.geometry.drop > 0 }
        note("Ice bar → pill dropped \(String(format: "%.0f", model.geometry.drop)) pt under it (owner \(monitor.obstructionOwner ?? "-"))"
             + " after \(dropped.map { String(format: "%.2f s", $0) } ?? "never")")
        #expect(dropped != nil && monitor.obstructionOwner == "Ice")
        let undropped = await wait(timeout: 5) { model.geometry.drop == 0 }
        note("Ice bar closed → drop back to 0 after \(undropped.map { String(format: "%.2f s", $0) } ?? "never")")
        #expect(undropped != nil)

        controller.pointerMoved(to: notchCenter, option: false)
        #expect(await wait { model.isHovering } != nil)
        let crowdPill = model.geometry.pillRect(size: model.size(for: .expanded))
        let crowdCenter = NSPoint(x: crowdPill.midX, y: crowdPill.midY)
        controller.pointerMoved(to: crowdCenter, option: false)
        let crowdOurs = await wait(timeout: 2) { hit(crowdCenter).number == controller.panelWindowNumber }
        note("crowd, hovering: click on the pill → \(hit(crowdCenter))")
        #expect(crowdOurs != nil, "pass-through panels at 27, 33 and 1000 must not take our clicks")
        controller.pointerMoved(to: NSPoint(x: 100, y: 100), option: false)
        #expect(await wait { !model.isHovering } != nil)

        // The one case we can't win: a level-1000 panel that catches clicks over our pill.
        if let dnk = crowd["dnk"] { quit(dnk) }
        try await Task.sleep(for: .milliseconds(400))
        let catching = try await launch("dnk", ["--catch-clicks"])
        try await Task.sleep(for: .milliseconds(600))
        controller.pointerMoved(to: notchCenter, option: false)
        _ = await wait { model.isHovering }
        controller.pointerMoved(to: crowdCenter, option: false)
        try await Task.sleep(for: .milliseconds(300))
        let lost = hit(crowdCenter)
        note("click-catching level-1000 panel over the pill, hovering: click → \(lost) (expected: that panel; we stay below pop-up menus)")
        #expect(lost.pid == catching)
        controller.pointerMoved(to: NSPoint(x: 100, y: 100), option: false)
        _ = await wait { !model.isHovering }

        quitAllStandIns()
        let emptied = await wait(timeout: 6) { monitor.neighbors.isEmpty && model.placement == .notch }
        note("all stand-ins quit → neighbors \(monitor.detected.map(\.name)) · placement \(model.placement) after \(emptied.map { String(format: "%.2f s", $0) } ?? "never")")
        #expect(emptied != nil)
        controller.stop()
        monitor.stop()
    }

    // MARK: - The real Bartender

    @Test(.enabled(if: bartenderRunning, "Bartender isn't running"), .enabled(if: notchScreen, "no display with a notch"))
    func realBartenderIsHandledAsBefore() async throws {
        let (controller, monitor, settings) = try makeController(ignoring: [])
        defer { controller.stop(); monitor.stop() }
        let model = controller.viewModel
        // The rule before this change: Bartender running with a tall window at the top above the menu bar.
        let pids = Set(NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier?.hasPrefix("com.surteesstudios.Bartender") == true
        }.map(\.processIdentifier))
        let topShelf = NotchNeighborMonitor.hasNotchPanel(NotchNeighborMonitor.onScreenWindows(), ownedBy: pids)
        _ = await wait(timeout: 2) { monitor.neighborPresent == topShelf }
        // Another app's window passing over the notch is confirmed first (a few hundred ms); then the pace is Bartender's.
        _ = await wait(timeout: 3) { monitor.pace != .confirming }
        note("real Bartender: Top Shelf canvas \(topShelf ? "present" : "absent") · detected \(monitor.detected.map { "\($0.name) live=\($0.live)" })"
             + " · placement \(model.placement) · bar \(monitor.obstruction.map { NSStringFromRect($0) } ?? "hidden") · pace \(monitor.pace)")
        #expect(monitor.neighborPresent == topShelf)
        #expect(model.placement == (topShelf ? .belowNotch : .notch))
        #expect(monitor.pace == .bar, "Bartender's bar is still watched every 500 ms")
        monitor.setAttentive(false, for: "test")
        _ = await wait(timeout: 3) { monitor.pace != .confirming }
        #expect(monitor.pace == .idle, "with nothing of ours showing, the bar isn't read twice a second")
        monitor.setAttentive(true, for: "test")
        _ = await wait(timeout: 3) { monitor.pace != .confirming }
        #expect(monitor.pace == .bar, "and it's watched closely again as soon as something shows")

        guard topShelf else { return }
        settings.notch.ignoredApps = [Self.bartender]
        let ignored = await wait { model.placement == .notch }
        note("Bartender set to \"don't make room\" → placement \(model.placement) after \(ignored.map { String(format: "%.2f s", $0) } ?? "never")")
        #expect(ignored != nil)
        settings.notch.ignoredApps = []
        #expect(await wait { model.placement == .belowNotch } != nil)
    }

    // MARK: - Cost

    @Test func windowListRefreshCost() {
        func ms(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
        }
        let monitor = NotchNeighborMonitor()
        var full: [Double] = []
        var listOnly: [Double] = []
        let clock = ContinuousClock()
        for _ in 0..<200 {
            monitor.refresh()
            full.append(ms(monitor.lastRefreshCost))
            listOnly.append(ms(clock.measure { _ = NotchNeighborMonitor.onScreenWindows() }))
        }
        monitor.stop()
        full.sort()
        listOnly.sort()
        let windows = NotchNeighborMonitor.onScreenWindows().count
        note(String(format: "refresh cost over 200 looks with %d on-screen windows: median %.2f ms · p90 %.2f ms · max %.2f ms "
                    + "(window list alone: median %.2f ms · p90 %.2f ms)",
                    windows, full[100], full[180], full[199], listOnly[100], listOnly[180]))
        #expect(full[100] < 20)
    }
}
