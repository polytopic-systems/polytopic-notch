import AppKit
import SwiftUI
import Testing
@testable import PolytopicNotch

/// Several docked apps in one process: each a real panel controller with its own dock, on the in-memory bus, on the
/// same test screen. The panels are real (transparent: their alpha is 0) so levels and click-through are the panels'
/// own.
@MainActor
final class DockedApps {
    struct App {
        let controller: NotchPanelController
        let content: NotchContent
        let dock: NotchDock
        let monitor: NotchNeighborMonitor
        let settings: InMemoryNotchSettings
        @MainActor var model: NotchViewModel { controller.viewModel }
        @MainActor var slot: NotchSlot { controller.viewModel.slot }
    }

    let bus = InMemoryNotchDockBus()
    let storage = InMemoryNotchDockSettingsStorage()
    let geometry: NotchGeometry
    let screen: NotchDockScreen
    var apps: [App] = []
    /// Where the (simulated) pointer is. `move(to:)` sends it to every app, as the real global mouse monitors do, and
    /// `settle()` looks again whenever an app's dock changed, as `dockChanged()` does with the real pointer.
    private(set) var pointer: NSPoint?
    private var seenRevision: [Int: Int] = [:]
    /// Every change of any app's visible state (slot, hover, mode, posts), with when it happened.
    private(set) var changes: [(at: Date, app: Int, state: String)] = []
    private var lastState: [Int: String] = [:]
    /// Samples that broke a click rule: a panel that takes clicks while not hovered, or outside its own part.
    private(set) var clickViolations: [String] = []
    /// Samples where more than one app's pill was open (expanding is exclusive in every style).
    private(set) var doubleOpen: [String] = []

    init(geometry: NotchGeometry = TestScreens.geometry(TestScreens.notches[0])) {
        self.geometry = geometry
        screen = NotchDockScreen(geometry: geometry, displayID: 1, scale: 2)
    }

    @discardableResult
    func add(_ appID: String, pid: Int32, start: Bool = true, configure: (NotchContent) -> Void = { _ in }) -> App {
        let content = NotchContent()
        content.symbol = "app.badge"
        content.title = appID.split(separator: ".").last.map(String.init) ?? appID
        content.showing = NotchBody(height: 60) { Text("showing") }
        content.expanded = NotchBody(height: 200) { Text("expanded") }
        configure(content)
        let dock = NotchDock(appID: appID, pid: pid, instance: "i\(pid)", symbol: "s\(pid)",
                             channel: bus.makeChannel(), trust: NotchDockStaticTrust(trusted: nil),
                             settings: NotchDockSettings(storage: storage), processes: ManualNotchDockProcessWatcher())
        let monitor = NotchNeighborMonitor(ownBundleID: appID)
        // Real notch apps on this Mac (Captioner, Boring Notch…) mustn't move the test pills: never make room
        // unless a test asks.
        let settings = InMemoryNotchSettings(NotchSettings(sharing: .never))
        let controller = NotchPanelController(content: content, settings: settings, neighbors: monitor, dock: dock)
        controller.followsRealPointer = false
        controller.screenOverride = (geometry, screen)
        controller.makePanelInvisibleForTests()
        let app = App(controller: controller, content: content, dock: dock, monitor: monitor, settings: settings)
        apps.append(app)
        if start { controller.start() }
        return app
    }

    /// Delivers until quiet, letting the controllers' watches run in between.
    func settle() async {
        for _ in 0..<12 {
            bus.flush()
            for app in apps { await app.dock.waitForVerifications() }
            try? await Task.sleep(for: .milliseconds(15))
            if !bus.hasPending { bus.flush() }
            recheckPointer()
            sample()
        }
    }

    /// The pointer moves: every app's monitor sees it.
    func move(to point: NSPoint) {
        pointer = point
        lastMove = Date()
        for app in apps {
            app.controller.testPointer = point
            app.controller.pointerMoved(to: point, option: false)
        }
        sample()
    }

    /// An app whose dock changed looks at the (still) pointer again, as `dockChanged()` does with the real one.
    private func recheckPointer() {
        guard let pointer else { return }
        for (i, app) in apps.enumerated() where seenRevision[i] != app.dock.revision {
            seenRevision[i] = app.dock.revision
            app.controller.pointerMoved(to: pointer, option: false)
        }
    }

    /// Records what changed since the last sample, and checks the click and exclusivity rules.
    func sample() {
        let now = Date()
        for (i, app) in apps.enumerated() {
            let slot = app.slot
            let state = "\(slot.role.rawValue) \(slot.frame.map { "\($0)" } ?? "-") \(slot.visibleFrame.map { "\($0)" } ?? "-") "
                + "hover=\(app.model.isHovering) mode=\(app.model.mode) posted=\(app.dock.postedCount)"
            if lastState[i] != state {
                lastState[i] = state
                changes.append((now, i, state))
            }
            if !app.controller.panelIgnoresMouse {
                if !app.model.isHovering {
                    clickViolations.append("app \(i) takes clicks while not hovered")
                } else if let pointer, !Self.drawnPart(app).contains(pointer) {
                    clickViolations.append("app \(i) takes clicks at \(pointer), outside its part \(Self.drawnPart(app))")
                }
            }
        }
        let open = apps.indices.filter { apps[$0].model.mode == .expanded }
        if open.count > 1 { doubleOpen.append("apps \(open) open at once") }
    }

    /// What of an app's pill is drawn now, in screen coordinates.
    static func drawnPart(_ app: App) -> CGRect {
        let model = app.model, slot = app.slot
        guard slot.isVisible else { return .null }
        if slot.role == .whole { return model.pillRect(size: model.drawnSize(for: model.mode)) }
        return slot.visibleFrame ?? .null
    }

    /// Keeps the pointer where it is for a while; returns the changes in that time (from the last move, if it came
    /// after the last hold).
    @discardableResult
    func hold(_ seconds: Double) async -> [(at: Date, app: Int, state: String)] {
        let start = Date()
        let from = lastMove.map { $0 > lastHoldEnd ? $0 : start } ?? start
        while Date().timeIntervalSince(start) < seconds { await settle() }
        lastHoldEnd = Date()
        return changes.filter { $0.at >= from }
    }
    private var lastMove: Date?
    private var lastHoldEnd = Date.distantPast

    /// Nothing changed in the last `seconds` (slots, hover, modes, posts).
    func quiet(for seconds: Double) -> Bool {
        guard let last = changes.last?.at else { return true }
        return Date().timeIntervalSince(last) >= seconds
    }

    /// How often an app's hover went on in a list of changes (from `hold`), counted from its state before them.
    func hoverOns(_ window: [(at: Date, app: Int, state: String)], app: Int) -> Int {
        guard let start = window.first?.at else { return 0 }
        var was = changes.last { $0.app == app && $0.at < start }?.state.contains("hover=true") ?? false
        var count = 0
        for c in window where c.app == app {
            let now = c.state.contains("hover=true")
            if now && !was { count += 1 }
            was = now
        }
        return count
    }

    func resetChecks() {
        clickViolations = []
        doubleOpen = []
    }

    func stop() {
        for app in apps {
            app.controller.stop()
            app.monitor.stop()
        }
    }

    /// Polls (other suites share the main actor).
    func wait(timeout: Double = 3, _ condition: () -> Bool) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            await settle()
            if condition() { return true }
        }
        return condition()
    }
}

@MainActor
@Suite(.serialized)
struct NotchDockControllerTests {
    static let a = "com.example.test.a", b = "com.example.test.b", c = "com.example.test.c"

    @Test func withoutADockNothingIsDocked() {
        let monitor = NotchNeighborMonitor()
        let controller = NotchPanelController(content: NotchContent(), settings: InMemoryNotchSettings(), neighbors: monitor)
        controller.followsRealPointer = false
        controller.start()
        defer { controller.stop(); monitor.stop() }
        #expect(controller.dock == nil && !controller.isDocked)
        #expect(controller.viewModel.dockCanvas == nil)
        #expect(controller.viewModel.slot == .solo)
        #expect(controller.panelFrame.width == 680, "today's panel")
    }

    @Test func aDockedAppAloneHangsWhereTheSoloPillDoes() async {
        let rig = DockedApps()
        defer { rig.stop() }
        let app = rig.add(Self.a, pid: 4_100_001) { $0.status = .showing; $0.want = .live }
        await rig.settle()
        #expect(app.controller.isDocked)
        let slot = app.slot
        #expect(slot.role == .whole && slot.mayExpand)
        #expect(app.controller.panelFrame == NotchPanelController.dockCanvas(for: rig.screen))
        // Same rect as the solo pill: top-centre on the notch, the showing size.
        let solo = rig.geometry.pillRect(size: app.model.size(for: .showing))
        #expect(app.model.pillRect(size: app.model.drawnSize(for: .showing)) == solo)
        #expect(app.controller.panelLevel.rawValue == 27)
        #expect(rig.bus.log.count >= 1, "hello")
    }

    @Test func mergedPanelsArePlacedAndLevelledPerSlot() async throws {
        let rig = DockedApps()
        defer { rig.stop() }
        let top = rig.add(Self.a, pid: 4_100_011) { $0.status = .showing; $0.want = .live }
        let low = rig.add(Self.b, pid: 4_100_012) { $0.status = .quiet; $0.want = .quiet }
        top.dock.setOrder([Self.a, Self.b])
        top.dock.setStyle(.merged)
        await rig.settle()
        #expect(low.dock.style == .merged)
        #expect(top.slot.role == .top && low.slot.role == .bottom)
        let notch = rig.geometry.notchRect
        let topFrame = try #require(top.slot.frame), lowFrame = try #require(low.slot.frame)
        #expect(topFrame.maxY == 1000 && topFrame.width == 500)
        #expect(lowFrame.maxY == notch.minY, "full tuck: the lower part starts just under the notch band")
        #expect(lowFrame.minX - topFrame.minX == 6 && topFrame.maxX - lowFrame.maxX == 6)
        #expect(top.controller.panelLevel.rawValue == 27 && low.controller.panelLevel.rawValue == 26)
        #expect(top.controller.panelFrame == low.controller.panelFrame)
        #expect(low.model.bodyTextWidth == 452, "a lower part's text is as wide as the part")

        // Hover the lower part: the whole stack rises together, order kept; it widens to the expanded width.
        let visible = try #require(low.slot.visibleFrame)
        low.controller.pointerMoved(to: NSPoint(x: visible.midX, y: visible.midY), option: false)
        #expect(await rig.wait { low.model.isHovering && top.slot.stackHovered })
        #expect(top.controller.panelLevel.rawValue == 100 && low.controller.panelLevel.rawValue == 99)
        #expect(top.slot.frame?.width == 560 && low.model.mode == .expanded && top.model.mode == .showing)
        #expect(!low.controller.panelIgnoresMouse && top.controller.panelIgnoresMouse)
    }

    @Test func splitPanelsGetOneWingEach() async throws {
        let rig = DockedApps()
        defer { rig.stop() }
        let left = rig.add(Self.a, pid: 4_100_021) { $0.status = .quiet; $0.want = .quiet }
        let right = rig.add(Self.b, pid: 4_100_022) { $0.status = .quiet; $0.want = .quiet }
        left.dock.setOrder([Self.a, Self.b])
        left.dock.setStyle(.split)
        await rig.settle()
        #expect(left.slot.role == .leftWing && right.slot.role == .rightWing)
        let notch = rig.geometry.notchRect
        let l = try #require(left.slot.frame), r = try #require(right.slot.frame)
        #expect(l.minX == notch.minX - 40 && r.maxX == notch.maxX + 40)
        #expect(r.minX - l.maxX == 6 && l.maxX > notch.minX && r.minX < notch.maxX, "the slit hides in the notch")
        #expect(left.controller.panelLevel.rawValue == 27 && right.controller.panelLevel.rawValue == 27)

        // The right app starts showing: its body spreads over the full width; the left keeps its quiet ear.
        right.content.status = .showing
        right.content.want = .notice
        #expect(await rig.wait { right.slot.bodyFrame != nil })
        #expect(right.slot.bodyFrame?.width == 500 && left.slot.bodyFrame == nil)
        #expect(right.model.bodyTextWidth == 464) // 500 − 2 × 18 (literals: Swift Testing on 6.4 mis-evaluates CGFloat arithmetic)
        // Reorder hot-swaps the sides in both apps.
        right.dock.setOrder([Self.b, Self.a])
        #expect(await rig.wait { right.slot.role == .leftWing && left.slot.role == .rightWing })
    }

    @Test func aHiddenSlotIsClickThroughAndNoHoverTarget() async {
        let rig = DockedApps()
        defer { rig.stop() }
        let owner = rig.add(Self.a, pid: 4_100_031) { $0.status = .showing; $0.want = .live }
        let other = rig.add(Self.b, pid: 4_100_032) { $0.status = .showing; $0.want = .notice }
        await rig.settle()
        #expect(owner.slot.role == .whole && other.slot.role == .hidden)
        #expect(other.controller.isPanelVisible, "stays ordered in, ready to take over")
        #expect(other.controller.panelIgnoresMouse)
        let notch = rig.geometry.notchRect
        let centre = NSPoint(x: notch.midX, y: notch.midY)
        #expect(!other.model.hoverContains(centre) && owner.model.hoverContains(centre))
        other.controller.pointerMoved(to: centre, option: false)
        owner.controller.pointerMoved(to: centre, option: false)
        #expect(await rig.wait { owner.model.isHovering })
        #expect(!other.model.isHovering && other.controller.panelIgnoresMouse)
        #expect(!owner.controller.panelIgnoresMouse)
    }

    @Test func anUrgentQuestionThatIsntGrantedAsksInItsFloatingWindow() async {
        let rig = DockedApps()
        defer { rig.stop() }
        let owner = rig.add(Self.a, pid: 4_100_041) { $0.status = .showing; $0.want = .live }
        let asker = rig.add(Self.b, pid: 4_100_042) { $0.status = .quiet; $0.want = .quiet }
        let prompts = NotchPromptWindowController(content: asker.content) { asker.controller.pillShowsPrompt }
        prompts.keepsOffscreen = true
        await rig.settle()
        // The owning app's pill is hovered: it keeps the notch; a new question waits in its floating window.
        let notch = rig.geometry.notchRect
        owner.controller.pointerMoved(to: NSPoint(x: notch.midX, y: notch.midY), option: false)
        #expect(await rig.wait { owner.model.isHovering && owner.dock.me.hovered })
        asker.content.prompt = NotchBody(height: 90) { Text("Allow?") }
        await rig.settle()
        #expect(asker.dock.me.want == .urgent, "a waiting question is announced as urgent")
        #expect(!asker.slot.mayAsk && !asker.controller.pillShowsPrompt)
        prompts.update()
        #expect(prompts.isShowing)
        // The pointer leaves: the question takes the notch and the floating window goes.
        owner.controller.pointerMoved(to: NSPoint(x: notch.midX, y: notch.minY - 700), option: false)
        #expect(await rig.wait { asker.slot.mayAsk && asker.model.mode == .asking })
        #expect(asker.controller.pillShowsPrompt)
        prompts.update()
        #expect(!prompts.isShowing)
        prompts.update()
    }

    /// The floating window mustn't flash up for the moment it takes to tell the other apps about a granted question.
    @Test func aGrantedQuestionNeverFlashesTheFloatingWindow() async {
        let rig = DockedApps()
        defer { rig.stop() }
        _ = rig.add(Self.a, pid: 4_100_081) { $0.status = .showing; $0.want = .live }
        let asker = rig.add(Self.b, pid: 4_100_082) { $0.status = .quiet; $0.want = .quiet }
        await rig.settle()
        #expect(asker.slot.role == .hidden)
        asker.content.prompt = NotchBody(height: 90) { Text("Allow?") }
        // Nothing has been announced or laid out yet, and the dock will grant it: the pill counts as showing it.
        #expect(!asker.slot.mayAsk)
        #expect(asker.controller.pillShowsPrompt)
        #expect(await rig.wait { asker.slot.mayAsk && asker.model.mode == .asking })
        #expect(asker.controller.pillShowsPrompt)
    }

    @Test func switcherDotsHandTheNotchOverAndTheClaimEndsWithTheVisit() async {
        let rig = DockedApps()
        defer { rig.stop() }
        let first = rig.add(Self.a, pid: 4_100_051) { $0.status = .showing; $0.want = .live }
        let second = rig.add(Self.b, pid: 4_100_052) { $0.status = .quiet; $0.want = .notice }
        first.dock.setStyle(.switcher)
        await rig.settle()
        let notch = rig.geometry.notchRect
        first.controller.pointerMoved(to: NSPoint(x: notch.midX, y: notch.midY), option: false)
        #expect(await rig.wait { first.model.mode == .expanded && first.slot.switcherDots.count == 2 })
        #expect(first.slot.switcherDots.map(\.isCurrent) == [true, false])
        // Click the other app's dot.
        first.model.onSwitcherDot?(4_100_052)
        #expect(await rig.wait { first.slot.role == .hidden && second.slot.role == .whole })
        #expect(first.controller.panelIgnoresMouse, "a hidden slot never takes clicks, even mid-handoff")
        // The pointer stays on the dock: the second app's pill opens under it.
        second.controller.pointerMoved(to: NSPoint(x: notch.midX, y: notch.midY), option: false)
        first.controller.pointerMoved(to: NSPoint(x: notch.midX, y: notch.midY), option: false)
        #expect(await rig.wait { second.model.isHovering && !first.model.isHovering })
        #expect(first.dock.me.switcherClaim != nil, "the claim lasts while the pointer is on the dock")
        #expect(second.slot.role == .whole)
        // The pointer leaves the dock: the claim ends.
        let away = NSPoint(x: notch.midX, y: notch.minY - 700)
        first.controller.pointerMoved(to: away, option: false)
        second.controller.pointerMoved(to: away, option: false)
        #expect(await rig.wait { first.dock.me.switcherClaim == nil && !second.model.isHovering })
        #expect(await rig.wait { first.slot.role == .whole }, "back to Priority: the live app")
    }

    @Test func peersAreNeverStrangers() async {
        let rig = DockedApps()
        defer { rig.stop() }
        let first = rig.add(Self.a, pid: 4_100_061) { $0.status = .quiet; $0.want = .quiet }
        let second = rig.add(Self.b, pid: 4_100_062) { $0.status = .quiet; $0.want = .quiet }
        await rig.settle()
        #expect(first.monitor.excludedPIDs == [4_100_062] && second.monitor.excludedPIDs == [4_100_061])
        // A peer that stops its dock (its pill turned off) says bye and stops being excluded.
        second.settings.notch.isShown = false
        #expect(await rig.wait { first.monitor.excludedPIDs.isEmpty })
        #expect(!second.controller.isDocked && !second.controller.isPanelVisible)
        second.settings.notch.isShown = true
        #expect(await rig.wait { first.monitor.excludedPIDs == [4_100_062] })
    }

    @Test func aStrangerSeenByOnePeerMovesEveryoneBelowIt() async {
        let rig = DockedApps()
        defer { rig.stop() }
        let first = rig.add(Self.a, pid: 4_100_071) { $0.status = .showing; $0.want = .live }
        let second = rig.add(Self.b, pid: 4_100_072) { $0.status = .quiet; $0.want = .quiet }
        await rig.settle()
        // "Always make room" in the second app is announced as seeing a stranger.
        second.settings.notch.sharing = .always
        #expect(await rig.wait { first.model.placement == .belowNotch })
        #expect(first.slot.placement == .belowNotch && first.controller.panelLevel.rawValue == 25,
                "sharing with a stranger keeps today's level")
        #expect(first.slot.frame?.maxY == rig.geometry.notchRect.minY - 5)
        #expect(first.model.pillRect(size: first.model.drawnSize(for: .showing)).maxY == rig.geometry.notchRect.minY - 5)
    }
}
