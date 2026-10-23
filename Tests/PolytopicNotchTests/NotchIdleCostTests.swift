import AppKit
import SwiftUI
import Foundation
import Testing
@testable import PolytopicNotch

/// Guards against work creeping back into idle around the notch: polling that doesn't stop, launch
/// handling that re-reads every app, a close watch kept while nothing of ours is showing.
@MainActor
struct NotchIdleCostTests {
    typealias App = NotchNeighborDetection.App

    @Test func runningAppsFollowLaunchesAndQuitsWithoutRereadingEveryApp() {
        let finder = App(pid: 10, bundleID: "com.apple.finder", name: "Finder")
        let bartender = App(pid: 20, bundleID: "com.surteesstudios.Bartender", name: "Bartender 7")
        let flaky = App(pid: 30, bundleID: "com.example.relaunchinghelper", name: "Relaunching Helper")
        var running = NotchRunningApps([finder, bartender])
        #expect(running.pids == [10, 20])
        #expect(Set(running.profiled.keys) == [20], "only apps with a neighbor profile are profiled")

        running.apply(launched: [flaky], quit: [])
        #expect(running.pids == [10, 20, 30])
        running.apply(launched: [], quit: [App(pid: 30, bundleID: "com.example.relaunchinghelper", name: "")])
        running.apply(launched: [], quit: [App(pid: 20, bundleID: "com.surteesstudios.Bartender", name: "")])
        #expect(running.pids == [10])
        #expect(running.profiled.isEmpty)
        #expect(running.apps[10]?.name == "Finder", "a quit record never overwrites a running app")
    }

    @Test func aLaunchTransitionStopsOnceTheAppHasQuit() {
        // An app that launches and quits again at once (a relaunching helper) needs one look, not eight.
        #expect(NotchNeighborMonitor.transitionContinues(following: [30], running: [10, 30], confirming: false))
        #expect(!NotchNeighborMonitor.transitionContinues(following: [30], running: [10], confirming: false))
        #expect(NotchNeighborMonitor.transitionContinues(following: [30], running: [10], confirming: true),
                "a window waiting for confirmation is still looked at again")
        #expect(NotchNeighborMonitor.transitionContinues(following: [30, 31], running: [31], confirming: false))
    }

    @Test func theBarIsOnlyWatchedClosely_whileThePillShowsSomething() {
        let bartender = App(pid: 20, bundleID: "com.surteesstudios.Bartender", name: "Bartender 7")
        let tracker = NotchNeighborTracker()
        #expect(NotchNeighborDetection.pace(apps: [bartender], tracker: tracker, attentive: true) == .bar)
        #expect(NotchNeighborDetection.pace(apps: [bartender], tracker: tracker, attentive: false) == .idle)
        #expect(NotchNeighborDetection.pace(apps: [App](), tracker: tracker, attentive: true) == .idle)
    }

    @Test func confirmingAnUnknownWindowHappensEvenWhileTheWatchIsRelaxed() {
        var tracker = NotchNeighborTracker()
        let window = NotchNeighborMonitor.WindowInfo(ownerPID: 40, layer: 25, bounds: CGRect(x: 900, y: 0, width: 200, height: 40))
        let sighting = NotchNeighborDetection.Sighting(pid: 40, bundleID: "com.example.island", name: "Island", profile: nil, window: window)
        _ = tracker.update([sighting], running: [40], now: Date())
        #expect(tracker.isConfirming)
        #expect(NotchNeighborDetection.pace(apps: [App](), tracker: tracker, attentive: false) == .confirming)
    }

    @Test func attentionIsCountedPerReason() {
        let monitor = NotchNeighborMonitor()
        #expect(!monitor.isAttentive)
        monitor.setAttentive(true, for: "pill")
        monitor.setAttentive(true, for: "settings")
        monitor.setAttentive(false, for: "pill")
        #expect(monitor.isAttentive, "the settings page still needs a close watch")
        monitor.setAttentive(false, for: "settings")
        #expect(!monitor.isAttentive)
    }

    @Test func theCadences() {
        #expect(NotchNeighborMonitor.Pace.bar.interval == .milliseconds(500))
        #expect(NotchNeighborMonitor.Pace.confirming.interval == .milliseconds(350))
        #expect(NotchNeighborMonitor.Pace.watching.interval == .seconds(1))
        #expect(NotchNeighborMonitor.Pace.idle.interval == .seconds(10))
        #expect(NotchNeighborTracker.confirmation == 0.3)
    }

    @Test func aHiddenPillRelaxesTheWatch() async throws {
        let content = NotchContent()
        let monitor = NotchNeighborMonitor()
        let controller = NotchPanelController(content: content, settings: InMemoryNotchSettings(), neighbors: monitor)
        controller.followsRealPointer = false
        controller.start()
        defer { controller.stop(); monitor.stop() }
        #expect(!monitor.isAttentive, "off: just the black notch, nothing to collide with")
        content.status = .showing
        try await Task.sleep(for: .milliseconds(50))
        #expect(monitor.isAttentive)
        content.status = .off
        try await Task.sleep(for: .milliseconds(50))
        #expect(!monitor.isAttentive)
        controller.stop()
        #expect(!monitor.isAttentive, "stopped: the pill no longer asks for a close watch")
    }

    /// A live list's return deadline is one task, alive only while a deadline is pending and a list shows the feed.
    @Test func aLiveListRunsOneCheckOnlyWhileShown() async throws {
        let feed = NotchLiveFeed<LiveItem>(edge: .top, timing: .init(actionGrace: .milliseconds(60), readingIdle: .milliseconds(120)))
        feed.publish([LiveItem(id: 1)])
        #expect(!feed.hasScheduledCheck, "live with no view: nothing scheduled")
        feed.attach()
        #expect(!feed.hasScheduledCheck, "live: nothing to wait for")
        feed.hold(.pointer)
        #expect(!feed.hasScheduledCheck, "held by the pointer: no deadline, no task")
        feed.publish([LiveItem(id: 2), LiveItem(id: 1)])
        feed.release(.pointer)
        #expect(feed.hasScheduledCheck)
        // The grace is 60 ms; a busy machine (a parallel test run, CI) may run the check late, never early.
        let deadline = ContinuousClock.now + .seconds(3)
        while feed.isHeld, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!feed.isHeld, "the grace ran out")
        #expect(feed.shown.map(\.id) == [2, 1])
        #expect(!feed.hasScheduledCheck, "the check ended with it")

        feed.scrolled(atLiveEdge: false, moved: true)
        #expect(feed.hasScheduledCheck)
        feed.detach()
        #expect(!feed.hasScheduledCheck, "closing the pill cancels it")
        #expect(!feed.isHeld)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!feed.hasScheduledCheck)
    }

    /// The list view attaches on appear and detaches on disappear, so a closed pill leaves nothing running.
    @Test func aLiveListViewDetachesWhenItGoes() async throws {
        let feed = NotchLiveFeed<LiveItem>(edge: .bottom)
        feed.publish((1...30).map { LiveItem(id: $0) })
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 300, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.alphaValue = 0
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: NotchLiveList(feed) { item in
            Text("Line \(item.id)").frame(height: 20)
        })
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(feed.isAttached)
        feed.scrolled(atLiveEdge: false, moved: true)
        #expect(feed.hasScheduledCheck)
        window.contentViewController = nil
        window.orderOut(nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!feed.isAttached)
        #expect(!feed.hasScheduledCheck)
        #expect(!feed.isHeld)
    }

    /// The status dot pulses in Core Animation (played by the window server), not as a SwiftUI `repeatForever`,
    /// which re-rendered from the app at 120 Hz while the pill was showing.
    @Test func theStatusDotPulsesInCoreAnimationOnlyWhileShowing() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 20, height: 20), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let view = NotchPulsingDotView(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
        window.contentView?.addSubview(view)
        view.pulsing = true
        #expect(view.isAnimating)
        view.pulsing = false
        #expect(!view.isAnimating, "quiet, nothing animates")
    }
}
