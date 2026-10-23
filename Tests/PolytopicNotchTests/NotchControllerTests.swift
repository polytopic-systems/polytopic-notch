import AppKit
import SwiftUI
import Testing
@testable import PolytopicNotch

/// The panel controller's lifecycle, its settings watch, hover with the menu hold, and the prompt window.
/// These put a real (transparent, click-through) panel at the notch, as the apps' own tests did.
@MainActor
@Suite(.serialized)
struct NotchControllerTests {
    func makeController(_ settings: InMemoryNotchSettings = InMemoryNotchSettings(), content: NotchContent = NotchContent(),
                        diagnostics: NotchDiagnostics? = nil) -> (NotchPanelController, NotchNeighborMonitor) {
        let monitor = NotchNeighborMonitor()
        let controller = NotchPanelController(content: content, settings: settings, neighbors: monitor, diagnostics: diagnostics)
        controller.followsRealPointer = false
        return (controller, monitor)
    }

    @Test func startAndStopAreIdempotent() async throws {
        let settings = InMemoryNotchSettings()
        let (controller, monitor) = makeController(settings)
        defer { controller.stop(); monitor.stop() }
        #expect(!controller.isStarted && !controller.isPanelVisible)
        controller.stop()                       // stopping before starting is harmless
        controller.start()
        controller.start()
        #expect(controller.isStarted && controller.isPanelVisible, "shown by default")

        // One settings change re-lays the pill out a fixed number of times (the settings and neighbor watches).
        let before = controller.layoutCount
        settings.notch.fontSize = 18
        try await Task.sleep(for: .milliseconds(80))
        let perChange = controller.layoutCount - before
        #expect(perChange > 0)

        controller.stop()
        controller.stop()
        #expect(!controller.isStarted && !controller.isPanelVisible)
        // Stopped: nothing follows the settings.
        let stopped = controller.layoutCount
        settings.notch.fontSize = 19
        try await Task.sleep(for: .milliseconds(80))
        #expect(controller.layoutCount == stopped)

        // Started again: the watches from the first run don't come back alongside the new ones. Doubled watches would
        // double the layouts per change; the neighbor monitor may add one now and then (other tests' windows come and
        // go), so the check is "fewer than double", not an exact count.
        controller.start()
        for size in [20.0, 21.0] {
            let restarted = controller.layoutCount
            settings.notch.fontSize = size
            try await Task.sleep(for: .milliseconds(80))
            let delta = controller.layoutCount - restarted
            #expect(delta > 0 && delta < 2 * perChange, "\(delta) layouts for one change, \(perChange) before the restart")
        }
    }

    /// Started while the app is still launching (a SwiftUI `App`'s `@State` initial value runs inside SwiftUI's scene
    /// update in `applicationWillFinishLaunching`; laying out the pill there aborted NotchDemo 1.0.0): nothing is laid
    /// out or shown until launching has finished, and a stop in between leaves nothing behind.
    @Test func startingWhileTheAppLaunchesWaitsForTheLaunch() async throws {
        let wasLaunching = NotchPanelController.isLaunching
        NotchPanelController.isLaunching = { true }
        defer { NotchPanelController.isLaunching = wasLaunching }
        let (controller, monitor) = makeController()
        defer { controller.stop(); monitor.stop() }

        controller.start()
        controller.start()
        #expect(controller.isStarted && controller.isWaitingForLaunch)
        #expect(controller.layoutCount == 0 && !controller.isPanelVisible, "nothing laid out inside the launch")

        NotchPanelController.isLaunching = { false }
        NotificationCenter.default.post(name: NSApplication.didFinishLaunchingNotification, object: NSApp)
        #expect(!controller.isWaitingForLaunch)
        #expect(controller.layoutCount > 0 && controller.isPanelVisible, "shown once launching finished")
        controller.stop()
        #expect(!controller.isStarted && !controller.isPanelVisible)

        // Stopped before launching finished: the launch then starts nothing.
        NotchPanelController.isLaunching = { true }
        let (early, earlyMonitor) = makeController()
        defer { earlyMonitor.stop() }
        early.start()
        early.stop()
        #expect(!early.isStarted && !early.isWaitingForLaunch)
        NotificationCenter.default.post(name: NSApplication.didFinishLaunchingNotification, object: NSApp)
        #expect(early.layoutCount == 0 && !early.isPanelVisible)
    }

    @Test func theControllerFollowsItsSettings() async throws {
        let settings = InMemoryNotchSettings()
        let diagnostics = NotchDiagnostics()
        let (controller, monitor) = makeController(settings, diagnostics: diagnostics)
        controller.start()
        defer { controller.stop(); monitor.stop() }
        settings.notch.isShown = false
        try await Task.sleep(for: .milliseconds(50))
        #expect(!controller.isPanelVisible)
        settings.notch.isShown = true
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.isPanelVisible)
        // Sharing set to Always moves it below the notch (on a notched screen) without a neighbor.
        settings.notch.sharing = .always
        try await Task.sleep(for: .milliseconds(50))
        let model = controller.viewModel
        #expect(controller.sharing == .always)
        #expect(model.placement == (model.geometry.hasNotch ? .belowNotch : .menuBar))
        #expect(diagnostics.sharing == .always)
        // The ignored apps reach the monitor.
        settings.notch.ignoredApps = [NotchIgnoredApp(bundleID: "com.example.island", name: "Island")]
        try await Task.sleep(for: .milliseconds(50))
        #expect(monitor.ignored == ["com.example.island"])
    }

    @Test func hidingCancelsAPendingHover() async throws {
        let (controller, monitor) = makeController()
        controller.start()
        defer { controller.stop(); monitor.stop() }
        let model = controller.viewModel
        let notch = model.geometry.hasNotch ? model.geometry.notchRect : model.geometry.hotZone
        controller.pointerMoved(to: NSPoint(x: notch.midX, y: notch.midY), option: false)
        controller.hide()
        try await Task.sleep(for: .milliseconds(250))
        #expect(!model.isHovering, "the hover that was on its way doesn't open a hidden panel")
    }

    /// The menu hold: while the pill's menu is open the pointer may be on the menu, outside the pill, and the pill
    /// stays open; once it closes, leaving closes the pill as usual.
    @Test func anOpenMenuHoldsThePillOpen() async throws {
        let (controller, monitor) = makeController()
        controller.start()
        defer { controller.stop(); monitor.stop() }
        let model = controller.viewModel
        let notch = model.geometry.hasNotch ? model.geometry.notchRect : model.geometry.hotZone
        let away = NSPoint(x: notch.midX, y: notch.minY - 600)
        controller.pointerMoved(to: NSPoint(x: notch.midX, y: notch.midY), option: false)
        #expect(await wait { model.isHovering && model.mode == .expanded })

        var duringMenu: (hovering: Bool, mode: NotchMode, level: NSWindow.Level)?
        model.presentMenu = { _, _ in
            // The pointer goes down onto the menu, far outside the pill.
            controller.pointerMoved(to: away, option: false)
            duringMenu = (model.isHovering, model.mode, controller.panelLevel)
        }
        model.popUpMenu(NSMenu(), from: nil)
        #expect(duringMenu?.hovering == true && duringMenu?.mode == .expanded)
        // The leave that happened while the menu was open didn't start a close.
        try await Task.sleep(for: .milliseconds(450))
        #expect(model.isHovering, "nothing was scheduled while the menu was open")

        controller.pointerMoved(to: away, option: false)
        #expect(await wait { !model.isHovering && model.mode == .hidden })
    }

    /// Polls (other suites share the main actor, so a fixed sleep can come up short).
    func wait(timeout: Double = 3, _ condition: () -> Bool) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test func thePromptWindowAsksWhenThePillCannot() {
        let content = NotchContent()
        final class Pill { var showsIt = false }
        let pill = Pill()
        let prompts = NotchPromptWindowController(content: content) { pill.showsIt }
        prompts.keepsOffscreen = true
        prompts.update()
        #expect(!prompts.isShowing)
        content.prompt = NotchBody(height: 120) { Text("Allow?") }
        prompts.update()
        #expect(prompts.isShowing)
        pill.showsIt = true
        prompts.update()
        #expect(!prompts.isShowing)
        pill.showsIt = false
        content.prompt = nil
        prompts.update()
        #expect(!prompts.isShowing)
        #expect(NotchPromptView.size(for: NotchBody(height: 120) { Color.clear }) == NSSize(width: 480, height: 128))
    }

    @Test func pillShowsPromptOnlyWhereItCanAsk() {
        let settings = InMemoryNotchSettings()
        let content = NotchContent()
        let (controller, monitor) = makeController(settings, content: content)
        defer { monitor.stop() }
        controller.viewModel.geometry = TestScreens.geometry(TestScreens.notches[0])
        #expect(!controller.pillShowsPrompt)
        content.prompt = NotchBody(height: 120) { Text("Allow?") }
        #expect(controller.pillShowsPrompt)
        settings.notch.isShown = false
        #expect(!controller.pillShowsPrompt, "the pill turned off: the floating window asks")
        settings.notch.isShown = true
        controller.viewModel.isYielding = true
        #expect(!controller.pillShowsPrompt, "stepping aside hides the question too: the floating window asks")
        controller.viewModel.isYielding = false
        #expect(controller.pillShowsPrompt)
        controller.viewModel.geometry = TestScreens.external
        #expect(!controller.pillShowsPrompt)
    }

    @Test func diagnosticsLogPlacementChangesOnce() {
        let lines = LogLines()
        let diagnostics = NotchDiagnostics(log: lines.log)
        let geometry = TestScreens.geometry(TestScreens.notches[0])
        diagnostics.record(geometry, display: .builtIn, sharing: .automatic, neighborPresent: false, obstruction: nil)
        diagnostics.record(geometry, display: .builtIn, sharing: .automatic, neighborPresent: false, obstruction: nil)
        diagnostics.record(geometry.sharingNotch(true), display: .builtIn, sharing: .automatic, neighborPresent: true, obstruction: nil)
        #expect(diagnostics.changes == 2)
        #expect(lines.all.count == 2)
        #expect(lines.all.last?.hasPrefix("placement → belowNotch on 1512×1000 screen (notch 188×32)") == true)
        let neighbor = NotchNeighborMonitor.Neighbor(pid: 20, bundleID: "theboringteam.boringnotch", name: "Boring Notch",
                                                     profileName: "Boring Notch", live: false)
        diagnostics.recordNeighbors([neighbor], ignored: [], obstruction: CGRect(x: 1, y: 2, width: 3, height: 4), barOwner: "Ice")
        #expect(diagnostics.neighborNames == ["Boring Notch"])
        #expect(lines.all.contains("notch neighbors: Boring Notch"))
        #expect(lines.all.contains("Ice bar showing at 1,2 3×4"))
    }
}
