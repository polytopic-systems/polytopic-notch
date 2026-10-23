import AppKit
import SwiftUI

/// Owns the notch pill: its panel, where it hangs (sharing the notch with other apps when needed), and
/// hover. The app creates it and calls `start()`; from then on it follows its settings (shown or not, display,
/// sharing, look), the neighbors and the screens.
///
/// With a `dock`, it also shares the notch with other docked apps: it keeps this app's announcement current
/// (want, mode, sizes, hover, menu, display, strangers and bars it sees), runs the dock while the pill is shown, and
/// places, levels and draws the pill from the dock's slot. Without one (`nil`) it behaves exactly as before.
@MainActor
public final class NotchPanelController {
    private let panel = NotchPanel()
    private let model: NotchViewModel
    private var monitors: [Any] = []
    private var hoverTask: Task<Void, Never>?
    /// What the pending `hoverTask` will set.
    private var pendingHover: Bool?
    /// Where the pointer was last seen (screen coordinates).
    private var lastPointer: NSPoint?
    private var lastIntentLook: ContinuousClock.Instant?
    private var screenObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private let neighbors: NotchNeighborMonitor
    /// Shares the notch with other docked apps; `nil`: solo, as before the dock existed.
    public let dock: NotchDock?
    /// The slot the app set (`slot`), used while no dock places the pill.
    private var appSlot: NotchSlot = .solo
    private let diagnostics: NotchDiagnostics?
    private let log: NotchLog
    private var started = false
    /// Bumped by every `start()`: an observation from an earlier run sees a different number and stops instead of
    /// re-arming, so stop-then-start never leaves two watches running side by side.
    private var generation = 0
    /// A neighbor is present (or sharing is set to Always) and the pill is off the notch for it.
    public private(set) var isSharing = false
    /// Whether to step below the notch for a neighbor. Follows `settings.notch.sharing` once started.
    public var sharing: NotchSharing = .automatic {
        didSet { if sharing != oldValue { layout() } }
    }
    /// This app's share of the notch: `solo` (today's behaviour) without a dock; with a running dock, the dock's slot
    /// (setting it then has no effect until the dock stops).
    public var slot: NotchSlot {
        get { model.slot }
        set {
            appSlot = newValue
            guard !isDocked, newValue != model.slot else { return }
            model.slot = newValue
            layout()
        }
    }

    /// - Parameters:
    ///   - content: what the app shows; the controller only reads it.
    ///   - settings: the notch settings (shown, display, sharing, looks), stored by the app.
    ///   - neighbors: the app's one neighbor monitor (other notch apps, menu bar managers).
    ///   - theme: colours and fonts; read live, so a palette change recolours the pill.
    ///   - metrics: sizes and spacing.
    ///   - diagnostics: records placement and neighbors for the app's diagnostics, if it has any.
    ///   - log: where the controller writes what it does.
    ///   - dock: shares the notch with other docked apps (`NotchDock`). `nil`: solo.
    public init(content: NotchContent, settings: any NotchSettingsStore, neighbors: NotchNeighborMonitor,
                theme: NotchTheme = .standard, metrics: NotchMetrics = .standard, diagnostics: NotchDiagnostics? = nil,
                log: NotchLog = .silent, dock: NotchDock? = nil) {
        self.neighbors = neighbors
        self.diagnostics = diagnostics
        self.log = log
        self.dock = dock
        let geometry = NotchGeometry.screen(for: settings.notch.display).map(NotchGeometry.init(screen:)) ?? .fallback
        model = NotchViewModel(content: content, settings: settings, geometry: geometry, theme: theme, metrics: metrics)
        sharing = settings.notch.sharing

        let host = NSHostingView(rootView: NotchView(model: model))
        host.sizingOptions = []
        panel.contentView = host
        model.onMenuClosed = { [weak self] in self?.menuClosed() }
        if let dock {
            model.onSwitcherDot = { [weak dock] pid in dock?.handNotch(to: pid) }
            // A docked app that leaves stops being excluded; forget it so it counts only if seen at the notch again.
            dock.onPeerLeft = { [weak neighbors] pid in neighbors?.forget(pid: pid) }
        }
    }

    /// The dock places the pill (it's running).
    public var isDocked: Bool { dock?.isRunning == true }

    /// Starts following the settings, the neighbors and the screens. Calling it again while started does nothing.
    ///
    /// Called while the app is still launching (from a SwiftUI `App`'s `@State` initial value, say: SwiftUI builds the
    /// scenes in `applicationWillFinishLaunching`), it is started at once (`isStarted`) but shows and follows nothing
    /// until launching has finished: laying out the pill's hosting view inside SwiftUI's own update aborts the app.
    /// Starting from `applicationDidFinishLaunching` or later needs no wait.
    public func start() {
        guard !started else { return }
        started = true
        generation += 1
        if Self.isLaunching() {
            let generation = generation
            launchObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.endLaunchWait()
                    guard self.started, self.generation == generation else { return }
                    self.begin()
                }
            }
            return
        }
        begin()
    }

    /// Whether the app is in `NSApplication.run()` but hasn't finished launching yet (tests replace it). A process
    /// without a running app (a test runner, a command-line tool) never finishes launching, so it doesn't wait.
    static var isLaunching: @MainActor () -> Bool = {
        NSApp?.isRunning == true && !NSRunningApplication.current.isFinishedLaunching
    }
    /// Waits for launching to finish when `start()` came too early.
    private var launchObserver: NSObjectProtocol?
    /// Started, but waiting for the app to finish launching before showing anything.
    var isWaitingForLaunch: Bool { launchObserver != nil }

    private func endLaunchWait() {
        if let launchObserver { NotificationCenter.default.removeObserver(launchObserver) }
        launchObserver = nil
    }

    private func begin() {
        layout()
        neighbors.start()
        watchNeighbors()
        watchMode()
        if dock != nil {
            // Before the dock starts (in watchSettings), so its hello already carries this app's state.
            watchAnnouncement()
            watchDock()
        }
        watchSettings()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.layout()
                self?.dock?.sayHello()
            }
        }
        if dock != nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.dock?.sayHello() }
            }
        }
        // "Display I'm working on" follows whichever screen the frontmost app is on.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.settings.notch.display == .active else { return }
                self.layout()
            }
        }
    }

    /// Hides the pill and stops following anything. Calling it again while stopped does nothing.
    public func stop() {
        guard started else { return }
        started = false
        if isWaitingForLaunch {
            // Nothing was shown or followed yet.
            endLaunchWait()
            return
        }
        dock?.stop()
        hide()
        layout()
        neighbors.setAttentive(false, for: Self.attentionReason)
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        screenObserver = nil
        activationObserver = nil
        wakeObserver = nil
    }

    public var isStarted: Bool { started }

    public func show() {
        layout()
        panel.orderFrontRegardless()
        startMouseTracking()
    }

    public func hide() {
        stopMouseTracking()
        // A pending hover would otherwise open the hidden panel to clicks.
        cancelHoverTask()
        model.isHovering = false
        model.hoverHold = nil
        model.hoverSince = nil
        panel.ignoresMouseEvents = true
        panel.orderOut(nil)
    }

    public func layout() {
        layoutCount += 1
        if let dock, dock.isRunning, let screen = currentScreen() {
            layoutDocked(dock, screen: screen)
            return
        }
        if model.dockCanvas != nil { model.dockCanvas = nil }
        if model.slot != appSlot { model.slot = appSlot }
        if let screenOverride {
            model.geometry = screenOverride.geometry.sharingNotch(sharing.shares(neighborPresent: neighbors.neighborPresent))
        } else if let screen = NotchGeometry.screen(for: model.settings.notch.display) {
            let ignored = Set(model.settings.notch.ignoredApps.map(\.bundleID))
            if ignored != neighbors.ignored { neighbors.ignored = ignored }
            let shares = sharing.shares(neighborPresent: neighbors.neighborPresent)
            let geometry = NotchGeometry(screen: screen).sharingNotch(shares)
                .avoiding(sharing == .never ? nil : neighbors.obstruction, reach: model.metrics.expandedWidth)
            isSharing = shares && geometry.placement != .notch
            if geometry != model.geometry {
                model.geometry = geometry
            }
            if !canYield { model.isYielding = false }
            diagnostics?.recordNeighbors(neighbors.neighbors,
                                         ignored: neighbors.detected.filter { ignored.contains($0.bundleID) },
                                         obstruction: neighbors.obstruction, barOwner: neighbors.obstructionOwner)
            diagnostics?.record(geometry, display: model.settings.notch.display, sharing: sharing,
                                neighborPresent: neighbors.neighborPresent, obstruction: neighbors.obstruction)
        }
        panel.setFrame(model.geometry.panelFrame(maxSize: model.metrics.panelSize), display: true)
        applyLevel()
    }

    /// Shown or hidden, and re-anchored when the display, sharing or look changes.
    private func watchSettings() {
        let generation = generation
        let settings = model.settings
        // Only the settings are tracked here; neighbors have their own watch.
        let notch = withObservationTracking {
            settings.notch
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.started, self.generation == generation else { return }
                self.watchSettings()
            }
        }
        self.sharing = notch.sharing
        if notch.isShown {
            // Docked only while the pill is shown: an app whose pill is off leaves the notch to the others.
            dock?.start()
            show()
        } else {
            dock?.stop()
            hide()
            layout()
        }
    }

    /// Re-anchor when a neighbor arrives or leaves, a menu bar manager's bar opens or closes, or the user
    /// changes which apps to ignore.
    private func watchNeighbors() {
        let generation = generation
        withObservationTracking {
            _ = neighbors.neighborPresent
            _ = neighbors.obstruction
            _ = model.settings.notch.ignoredApps
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.started, self.generation == generation else { return }
                self.layout()
                self.watchNeighbors()
            }
        }
    }

    /// The neighbor watch only needs to be close while the pill shows something (see
    /// `NotchNeighborMonitor.isAttentive`); hidden, it's the black notch or nothing at all.
    private func watchMode() {
        let generation = generation
        let showing = withObservationTracking {
            model.mode != .hidden
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.started, self.generation == generation else { return }
                self.watchMode()
            }
        }
        neighbors.setAttentive(showing, for: Self.attentionReason)
    }

    public static let attentionReason = "notch pill"

    /// Whether the pill shows the content's question itself, so the floating window needn't. With a dock, a question
    /// that just arrived counts as soon as the dock will grant it, so the floating window doesn't flash up for the
    /// moment it takes to tell the other apps.
    public var pillShowsPrompt: Bool {
        // Stepping aside (Option-hover) hides the pill, question and all: the floating window asks meanwhile.
        guard model.settings.notch.isShown, !model.isYielding else { return false }
        if model.canAsk { return true }
        guard let dock, dock.isRunning, model.content.prompt != nil, model.placement != .menuBar,
              let screen = currentScreen() else { return false }
        var asking = dock.me
        asking.want = .urgent
        asking.mode = .asking
        asking.sizes = model.dockSizes
        return dock.slot(for: screen.dock, metrics: NotchDockMetrics(model.metrics), ifMe: asking)?.mayAsk == true
    }

    // MARK: - Hover

    private func startMouseTracking() {
        guard monitors.isEmpty, followsRealPointer else { return }
        // Modifier changes matter too: Option decides who gets the notch when it's shared.
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp, .flagsChanged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func stopMouseTracking() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func pointerMoved() {
        if let testPointer {
            pointerMoved(to: testPointer, option: false)
            return
        }
        pointerMoved(to: NSEvent.mouseLocation, option: NSEvent.modifierFlags.contains(.option))
    }

    /// Option-hover hands the notch to the other app: below a notch, or under the stand-in notch that
    /// notch apps draw on screens without one.
    private var canYield: Bool {
        model.placement == .belowNotch || (model.placement == .menuBar && isSharing)
    }

    /// The pointer moved (or Option was pressed or released). Public so tests can drive it.
    public func pointerMoved(to location: NSPoint, option: Bool) {
        let moved = lastPointer != location
        lastPointer = location
        defer { updateClickThrough() }
        if let dock, isDocked, dock.me.switcherClaim != nil, !claimArea().contains(location) {
            // Switcher: a dot click lasts for one visit to the dock. The pointer has left it.
            dock.endHoverSession()
        }
        if model.isMenuOpen {
            // The pill's pop-up menu is open and the pointer may be on it, outside the pill: hover, level and
            // yielding stay as they are until it closes (`menuClosed` looks again).
            cancelHoverTask()
            return
        }
        if canYield {
            let notch = model.geometry.hasNotch ? model.geometry.notchRect : model.geometry.hotZone
            if model.isYielding {
                // Stay out of the way until the pointer leaves the neighbor's panel area.
                if model.yieldZone().contains(location) { return }
                model.isYielding = false
            } else if option, notch.insetBy(dx: -4, dy: -4).contains(location) {
                // Option-hover on the notch hands it to the neighbor: close ours and fade the pill out.
                cancelHoverTask()
                setHovering(false)
                model.isYielding = true
                return
            }
        }
        if let dock, isDocked, model.dockCanvas != nil {
            dockedPointerMoved(to: location, moved: moved, dock: dock)
            return
        }
        let inside = model.hoverContains(location)
        guard inside != model.isHovering else {
            cancelHoverTask()
            return
        }
        if inside, model.mode == .hidden, !neighbors.isAttentive,
           lastIntentLook.map({ ContinuousClock.now - $0 > .seconds(1) }) ?? true {
            // About to open from hidden: look at the neighbors now (once per approach), so the pill
            // opens in the right place.
            lastIntentLook = .now
            neighbors.refresh()
        }
        // Small delays so passing over the notch on the way to a menu doesn't pop the panel open,
        // and a brief exit doesn't snap it shut.
        scheduleHover(inside)
    }

    /// Docked hover. Every app decides its own hover from the same layout, and a hover change re-lays out everyone,
    /// so the rules are made so that no change can move a part away from a still pointer:
    /// - The pointer on another app's part, and that app hovered: let go at once (a handover, not a leave). On a peer
    ///   that isn't hovered yet: keep the hover until it is (the peer opens after 140 ms of rest, this closes after
    ///   350 ms), so the dock is never without an open pill mid-handover, which would move the parts.
    /// - A hidden Split app's ear counts only while another app's pill is open (a hover session).
    /// - Otherwise the usual delays (open 140 ms, close 350 ms). A pending change isn't restarted when the pointer
    ///   hasn't moved (a re-check after a dock change), so peers' announcements can't starve it.
    private func dockedPointerMoved(to location: NSPoint, moved: Bool, dock: NotchDock) {
        // Far from the dock with nothing going on (most moves): no layout to look at.
        if !model.isHovering, hoverTask == nil, let canvas = model.dockCanvas, !canvas.contains(location) { return }
        let peers = dock.participants.filter { $0.pid != dock.me.pid }
        let slots = currentScreen().map { dock.layout(for: $0.dock, metrics: NotchDockMetrics(model.metrics)) } ?? [:]
        let peerUnder = peers.first { peer in
            guard let slot = slots[peer.pid] else { return false }
            return Self.hitRect(of: slot)?.contains(location) ?? false
        }
        let mine = model.dockHitRect
        let onHandoff = !model.slot.isVisible && (mine?.contains(location) ?? false)
        if model.isHovering {
            if let peerUnder, peerUnder.isSticky, !onHandoff {
                cancelHoverTask()
                setHovering(false)
            } else if model.hoverContains(location) {
                cancelHoverTask()
            } else {
                // Off this pill. On a peer that hasn't taken the hover yet, it will once the pointer rests there (its
                // open delay is shorter than this close delay); should it never, this lets go all the same.
                scheduleHover(false, restart: moved)
            }
            return
        }
        let session = dock.participants.contains(where: \.isSticky) || model.slot.isOpen
        let onMine = (mine?.contains(location) ?? false) && (onHandoff ? session : true)
        guard onMine, onHandoff || peerUnder == nil else {
            cancelHoverTask()
            return
        }
        scheduleHover(true, restart: moved)
    }

    /// What of a docked app's slot the pointer can be on (as `NotchViewModel.dockHitRect`, from the slot alone).
    static func hitRect(of slot: NotchSlot) -> CGRect? {
        slot.isVisible ? (slot.visibleFrame ?? slot.frame) : slot.handoffFrame
    }

    private func scheduleHover(_ hovering: Bool, restart: Bool = true) {
        if !restart, hoverTask != nil, pendingHover == hovering { return }
        hoverTask?.cancel()
        pendingHover = hovering
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: hovering ? Self.openDelay : Self.closeDelay)
            guard let self, !Task.isCancelled else { return }
            self.hoverTask = nil
            self.pendingHover = nil
            self.setHovering(hovering)
        }
    }

    private func cancelHoverTask() {
        hoverTask?.cancel()
        hoverTask = nil
        pendingHover = nil
    }

    public static let openDelay: Duration = .milliseconds(140)
    public static let closeDelay: Duration = .milliseconds(350)

    /// The pill's menu closed: if the pointer ended up off the pill, it closes after the usual delay.
    private func menuClosed() {
        guard (followsRealPointer && !monitors.isEmpty) || testPointer != nil else { return }
        pointerMoved()
    }

    private func setHovering(_ hovering: Bool) {
        if hovering != model.isHovering {
            // Docked: announce what was under the pointer as the hover began, so the open part keeps covering it.
            model.hoverHold = hovering && model.dockCanvas != nil
                ? lastPointer.flatMap { p in model.dockHitRect.flatMap { $0.contains(p) ? $0 : nil } }
                : nil
            model.hoverSince = hovering && model.dockCanvas != nil ? Date() : nil
        }
        model.isHovering = hovering
        updateClickThrough()
        applyLevel()
        // Equal levels order by recency: come to the front of our level while the user is on the pill.
        if hovering, panel.isVisible { panel.orderFrontRegardless() }
    }

    /// The panel takes clicks only while hovered and only where its own pill or part is drawn. A transparent window
    /// whose `ignoresMouseEvents` is set to false takes every click over its whole frame, transparent pixels included,
    /// and a docked panel's frame is the 1000 × 520 canvas: it ate clicks meant for the other apps' parts and for menu
    /// bar items beside the notch. The pointer is followed anyway, so the flag follows it; never mid-drag.
    private func updateClickThrough() {
        let takes = model.isHovering && (model.dockCanvas == nil || model.slot.isVisible)
            && (lastPointer.map(model.clickContains) ?? false)
        guard panel.ignoresMouseEvents == takes else { return }
        if !takes, followsRealPointer, NSEvent.pressedMouseButtons != 0 { return }
        panel.ignoresMouseEvents = !takes
    }

    private func applyLevel() {
        var level = NotchPanel.level(placement: model.placement, sharing: isSharing, hovering: model.isHovering)
        if model.dockCanvas != nil {
            // A Merged stack moves to the hovered level together and keeps its order (100 − rank, else 27 − rank).
            let slot = model.slot
            let base = slot.stackHovered ? NotchPanel.hoverLevel.rawValue : level.rawValue
            level = NSWindow.Level(rawValue: base + slot.levelOffset)
        }
        guard panel.level != level else { return }
        panel.level = level
        log.debug("panel level → \(level.rawValue)\(model.isHovering ? " (pointer on the pill)" : "")")
    }

    // MARK: - Dock

    /// The screen the pill is on, as the pill and the dock see it.
    private func currentScreen() -> (geometry: NotchGeometry, dock: NotchDockScreen)? {
        if let screenOverride { return screenOverride }
        guard let screen = NotchGeometry.screen(for: model.settings.notch.display) else { return nil }
        return (NotchGeometry(screen: screen), NotchDockScreen(screen: screen))
    }

    /// The docked panel's fixed frame: whole points, from the top of the screen, centred on the notch, big enough for
    /// any slot of any style, so a slot that moves animates inside it.
    public static func dockCanvas(for screen: NotchDockScreen, metrics: NotchMetrics = .standard) -> CGRect {
        let width = min(screen.screenFrame.width, max(metrics.panelSize.width, 1000))
        let height = max(metrics.panelSize.height, 520)
        let x = (screen.centerX - width / 2).rounded(.down)
        return CGRect(x: x, y: screen.screenFrame.maxY - height, width: width, height: height)
    }

    private func layoutDocked(_ dock: NotchDock, screen: (geometry: NotchGeometry, dock: NotchDockScreen)) {
        let ignored = Set(model.settings.notch.ignoredApps.map(\.bundleID))
        if ignored != neighbors.ignored { neighbors.ignored = ignored }
        if dock.me.displayID != screen.dock.displayID {
            dock.update { $0.displayID = screen.dock.displayID }
        }
        let metrics = NotchDockMetrics(model.metrics)
        let slot = dock.slot(for: screen.dock, metrics: metrics) ?? .hidden(.notch)

        // Hang where the dock hangs: below a stranger's notch or a bar any docked app sees, as if this app saw it.
        var geometry = screen.geometry.sharingNotch(slot.placement == .belowNotch)
        if geometry.placement != .notch, let anchor = slot.anchorY {
            geometry.drop = max(0, geometry.anchorY - anchor)
        }
        let strangers = dock.participants.contains { $0.displayID == screen.dock.displayID && $0.seesStranger }
        isSharing = strangers && geometry.placement != .notch
        if geometry != model.geometry { model.geometry = geometry }
        if slot != model.slot {
            log.debug("dock slot → \(slot.role.rawValue)\(slot.frame.map { " at \(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "")")
            model.slot = slot
        }
        let canvas = Self.dockCanvas(for: screen.dock, metrics: model.metrics)
        if model.dockCanvas != canvas { model.dockCanvas = canvas }
        if !canYield { model.isYielding = false }
        diagnostics?.recordNeighbors(neighbors.neighbors, ignored: neighbors.detected.filter { ignored.contains($0.bundleID) },
                                     obstruction: neighbors.obstruction, barOwner: neighbors.obstructionOwner)
        diagnostics?.record(geometry, display: model.settings.notch.display, sharing: sharing,
                            neighborPresent: neighbors.neighborPresent, obstruction: neighbors.obstruction)
        if panel.frame != canvas { panel.setFrame(canvas, display: true) }
        updateClickThrough()
        applyLevel()
    }

    /// The area of the dock: a Switcher claim ends when the pointer leaves it. This app's own open pill (where the
    /// dot was clicked), every app's part as laid out now (the target's open pill), and the notch, with a margin.
    private func claimArea() -> CGRect {
        var area = model.geometry.pillRect(size: model.size(for: .expanded)).union(model.geometry.notchRect)
        if let dock, let screen = currentScreen() {
            for slot in dock.layout(for: screen.dock, metrics: NotchDockMetrics(model.metrics)).values {
                if let rect = Self.hitRect(of: slot) { area = area.union(rect) }
            }
        }
        return area.insetBy(dx: -20, dy: -20)
    }

    /// What this app tells the other docked apps. Reads only what decides the layout (never the meter or captions),
    /// so an idle or merely talking app posts nothing.
    struct Announced: Equatable {
        var want: NotchWant
        var mode: NotchMode
        var restMode: NotchMode
        var sizes: NotchDockSizes
        var hovered: Bool
        var menuOpen: Bool
        var hoverHold: CGRect?
        var hoverSince: Date?
        var seesStranger: Bool
        var barRect: CGRect?
        var symbol: String
    }

    func announced() -> Announced {
        let content = model.content
        // A question waiting is urgent, whatever the app said.
        let want = content.prompt != nil ? max(content.want, .urgent) : content.want
        let sizes = model.dockSizes
        let sharing = model.settings.notch.sharing
        return Announced(want: want, mode: model.mode, restMode: model.restMode, sizes: sizes,
                         hovered: model.isHovering, menuOpen: model.isMenuOpen,
                         hoverHold: model.isHovering ? model.hoverHold : nil,
                         hoverSince: model.isHovering ? model.hoverSince : nil,
                         seesStranger: sharing.shares(neighborPresent: neighbors.neighborPresent),
                         barRect: sharing == .never ? nil : neighbors.obstruction, symbol: content.symbol)
    }

    /// Keeps the announcement current. The dock posts only when a field changed.
    private func watchAnnouncement() {
        guard let dock else { return }
        let generation = generation
        let next = withObservationTracking {
            announced()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.started, self.generation == generation else { return }
                self.watchAnnouncement()
            }
        }
        dock.update {
            $0.want = next.want
            $0.mode = next.mode
            $0.restMode = next.restMode
            $0.sizes = next.sizes
            $0.hovered = next.hovered
            $0.menuOpen = next.menuOpen
            $0.hoverHold = next.hoverHold
            $0.hoverSince = next.hoverSince
            $0.seesStranger = next.seesStranger
            $0.barRect = next.barRect
            $0.symbol = next.symbol
        }
    }

    /// Re-places the pill whenever a layout input changes (an announcement, the shared settings, a hold running out).
    private func watchDock() {
        guard let dock else { return }
        let generation = generation
        withObservationTracking {
            _ = dock.revision
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.started, self.generation == generation else { return }
                self.dockChanged()
                self.watchDock()
            }
        }
    }

    private func dockChanged() {
        guard let dock else { return }
        let excluded = dock.excludedPIDs
        if neighbors.excludedPIDs != excluded { neighbors.excludedPIDs = excluded }
        layout()
        // The slot may have moved under (or away from) the pointer: look at it again now, not at the next move.
        if (followsRealPointer && !monitors.isEmpty) || testPointer != nil { pointerMoved() }
    }

    // MARK: - Test hooks

    /// Tests that drive `pointerMoved(to:option:)` themselves turn this off before `show()`/`start()`, so
    /// the real pointer doesn't interfere.
    public var followsRealPointer = true
    /// Tests: where the pointer is, for the controller's own second looks (after a dock change, a menu closing).
    var testPointer: NSPoint?
    public var panelWindowNumber: Int { panel.windowNumber }
    public var panelLevel: NSWindow.Level { panel.level }
    public var isPanelVisible: Bool { panel.isVisible }
    public var viewModel: NotchViewModel { model }
    /// How many times `layout()` ran (tests count the watches that call it).
    private(set) var layoutCount = 0
    /// Tests: a screen instead of the real one, so docked layouts are the same on every Mac.
    var screenOverride: (geometry: NotchGeometry, dock: NotchDockScreen)?
    var panelFrame: CGRect { panel.frame }
    var panelIgnoresMouse: Bool { panel.ignoresMouseEvents }
    /// Tests that show real content keep the panel transparent.
    func makePanelInvisibleForTests() { panel.alphaValue = 0 }
}
