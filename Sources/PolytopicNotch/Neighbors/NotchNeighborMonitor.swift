import AppKit
import Observation

/// Watches for other apps that put things where our pill lives, and reports two things:
/// - **Neighbors** that live on the notch (Boring Notch, Atoll, Bartender's Top Shelf, an unknown island…).
///   While one is present the pill hangs just below the notch.
/// - **A bar** that a menu bar manager (the Bartender Bar, the Ice Bar…) drops down just under the menu
///   bar. The pill steps under it while it's showing.
///
/// The rules in short: known apps by bundle-id prefix (`NotchNeighborProfiles.swift`); unknown apps by a
/// window hanging from the top edge over the notch, seen twice 0.3 s apart, then sticky until that app
/// quits. `com.apple.*`, full-width strips, popovers and full-screen overlays never count.
///
/// Nothing here needs Screen Recording: owner PID, layer and bounds come with every window-list entry.
/// The rules are pure functions over a window list (`NotchNeighborDetection`, `NotchNeighborTracker`)
/// so they can be tested without the apps; this class just feeds them.
///
/// The apps never move or hide other apps' menu bar items and ask for no Accessibility or Screen
/// Recording permission; that is a product decision, so everything here works from the window list alone.
///
/// Each app makes one (`extension NotchNeighborMonitor { static let shared = NotchNeighborMonitor(log: …) }`)
/// and hands it to its panel controller and its Settings rows.
@MainActor
@Observable
public final class NotchNeighborMonitor {
    public typealias Neighbor = NotchNeighborTracker.Neighbor

    /// Every app currently counted as using the notch, including ones the user told us to ignore.
    public private(set) var detected: [Neighbor] = []
    /// Bundle IDs the user doesn't want us to make room for.
    public var ignored: Set<String> = []
    /// A bar currently showing just under the menu bar, in screen coordinates (origin bottom-left).
    public private(set) var obstruction: CGRect?
    /// The app whose bar that is.
    public private(set) var obstructionOwner: String?

    /// The neighbors we make room for.
    public var neighbors: [Neighbor] { detected.filter { !ignored.contains($0.bundleID) } }
    public var neighborPresent: Bool { detected.contains { !ignored.contains($0.bundleID) } }

    /// Processes that never count as neighbors, whatever their windows do.
    ///
    /// With a dock, `NotchPanelController` puts the docked apps' pids here, so a peer's pill is never mistaken
    /// for a stranger's island. A pid added here is forgotten at once, so it stops counting without waiting to quit.
    @ObservationIgnored public var excludedPIDs: Set<pid_t> = [] {
        didSet {
            guard excludedPIDs != oldValue else { return }
            for pid in excludedPIDs.subtracting(oldValue) {
                if let gone = tracker.forget(pid: pid) { log.notice("notch neighbor gone: \(gone.name) (excluded)") }
            }
            if started { refresh() }
        }
    }

    /// Drops a pid from the sticky tracker (a docked app that left the dock), so it counts again only if it's seen
    /// at the notch again.
    public func forget(pid: pid_t) {
        if let gone = tracker.forget(pid: pid) {
            log.notice("notch neighbor gone: \(gone.name) (forgotten)")
            let current = tracker.neighbors.values.sorted { ($0.name, $0.pid) < ($1.name, $1.pid) }
            if current != detected { detected = current }
        }
    }

    /// How long the last window-list refresh took (copying and filtering the list), for the console.
    @ObservationIgnored public private(set) var lastRefreshCost: Duration = .zero
    @ObservationIgnored public private(set) var refreshCount = 0

    @ObservationIgnored public let log: NotchLog
    @ObservationIgnored private var tracker = NotchNeighborTracker()
    /// Running apps: read in full once, then kept up to date from each launch and quit.
    @ObservationIgnored private var running = NotchRunningApps()
    private var apps: [pid_t: NotchNeighborDetection.App] { running.apps }
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var transition: Task<Void, Never>?
    /// Apps launched since the current transition began; it ends early once all of them have quit.
    @ObservationIgnored private var transitionPIDs: Set<pid_t> = []
    /// Why something of ours is on screen near the notch right now (see `setAttentive`).
    @ObservationIgnored private var attention: Set<String> = []
    @ObservationIgnored private var appsObservation: NSKeyValueObservation?
    @ObservationIgnored private var started = false
    /// (pid, reason) pairs already logged, so each exclusion is explained once per process.
    @ObservationIgnored private var explained: Set<String> = []
    @ObservationIgnored private let ownBundleID: String?

    /// `ownBundleID`: windows of other copies of this app never count (defaults to this app's).
    public init(log: NotchLog = .silent, ownBundleID: String? = Bundle.main.bundleIdentifier) {
        self.log = log
        self.ownBundleID = ownBundleID
    }

    /// How often to look at the window list.
    public enum Pace: Equatable, Sendable {
        /// A menu bar manager is running: its bar comes and goes as the user reveals hidden items.
        case bar
        /// An unknown app just put a window over the notch; look again to confirm it's staying.
        case confirming
        /// A known notch app is running but hasn't shown itself at the notch yet (or, like Top Shelf,
        /// can be switched off while it runs).
        case watching
        /// Nothing to watch: only a slow sweep for unknown notch apps.
        case idle

        public var interval: Duration {
            switch self {
            case .bar: .milliseconds(500)
            case .confirming: .milliseconds(350)
            case .watching: .seconds(1)
            case .idle: .seconds(10)
            }
        }
    }
    public private(set) var pace: Pace = .idle

    /// Whether anything of ours that a neighbor could collide with is on screen: the pill while it
    /// shows something, or the Settings page that lists neighbors. While nothing is, where a menu bar
    /// manager's bar or a notch app's panel sits can't matter yet, so the watch drops to the slow sweep
    /// (instead of reading the window list twice a second for as long as Bartender runs). Becoming
    /// attentive looks at once, so placement is current before anything is drawn.
    public var isAttentive: Bool { !attention.isEmpty }

    /// `reason` names who needs a close watch; the watch is close while any reason is on.
    public func setAttentive(_ on: Bool, for reason: String) {
        let was = isAttentive
        if on { attention.insert(reason) } else { attention.remove(reason) }
        guard started, isAttentive != was else { return }
        if isAttentive {
            refresh()
        } else {
            updatePace()
            schedule()
        }
    }

    public func start() {
        guard !started else { return }
        started = true
        running = NotchRunningApps(NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }.map(Self.app(for:)))
        // Launches and quits arrive through KVO on the running-apps list: NSWorkspace's launch and terminate
        // notifications skip agent apps (no Dock icon), which is what most notch apps are.
        appsObservation = NSWorkspace.shared.observe(\.runningApplications, options: [.old, .new]) { [weak self] _, change in
            let launched = (change.newValue ?? []).map(Self.app(for:))
            // A quit app needs only its pid and bundle ID (nothing that might ask LaunchServices about it).
            let quit = (change.oldValue ?? []).map {
                NotchNeighborDetection.App(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier, name: "")
            }
            let replaced = change.kind == .setting
            Task { @MainActor in self?.appsChanged(launched: launched, quit: quit, replaced: replaced) }
        }
        refresh()
    }

    /// Only properties NSRunningApplication fetches once per app. Dynamic ones (`isTerminated`,
    /// `activationPolicy`…) cost a LaunchServices round trip each when their cache is stale, which
    /// added up to tens of milliseconds per launch anywhere on the system with ~250 apps running.
    nonisolated private static func app(for running: NSRunningApplication) -> NotchNeighborDetection.App {
        NotchNeighborDetection.App(pid: running.processIdentifier, bundleID: running.bundleIdentifier,
                                   name: running.localizedName ?? running.bundleIdentifier ?? "pid \(running.processIdentifier)")
    }

    public func stop() {
        poll?.cancel()
        transition?.cancel()
        appsObservation?.invalidate()
        appsObservation = nil
        started = false
    }

    private func appsChanged(launched: [NotchNeighborDetection.App], quit: [NotchNeighborDetection.App], replaced: Bool) {
        guard started else { return }
        if replaced {
            running = NotchRunningApps(launched)
        } else {
            running.apply(launched: launched, quit: quit)
        }
        // Any app could be a notch app we don't know; their windows take a few seconds to settle.
        let others = launched.filter { $0.bundleID != ownBundleID }
        if !others.isEmpty {
            followTransition(others.map(\.pid))
        } else if quit.contains(where: { tracker.knows($0.pid) || $0.bundleID.flatMap(NotchNeighborProfile.profile(for:)) != nil }) {
            refresh()
        }
    }

    /// An app just launched. Windows appear over a few seconds, so look closely until things settle
    /// instead of waiting for the next poll. Some apps launch and quit again within a moment, over and
    /// over (a helper that keeps relaunching); once every app this transition is following has quit
    /// and nothing is waiting for confirmation, there is nothing left to see.
    private func followTransition(_ pids: [pid_t]) {
        transition?.cancel()
        transitionPIDs.formUnion(pids)
        transition = Task { [weak self] in
            var elapsed = 0
            for delay in Self.transitionSteps {
                try? await Task.sleep(for: .milliseconds(delay - elapsed))
                elapsed = delay
                guard let self, !Task.isCancelled else { return }
                guard Self.transitionContinues(following: self.transitionPIDs, running: self.running.pids,
                                               confirming: self.tracker.isConfirming) else { break }
                self.refresh()
            }
            self?.transitionPIDs = []
        }
    }

    /// Milliseconds after a launch at which the window list is read.
    public static let transitionSteps = [0, 150, 350, 700, 1_200, 2_000, 3_500, 6_000]

    /// A transition keeps looking while an app it follows is still running, or a sighting awaits confirmation.
    nonisolated public static func transitionContinues(following: Set<pid_t>, running: Set<pid_t>, confirming: Bool) -> Bool {
        confirming || !following.isDisjoint(with: running)
    }

    private func schedule() {
        poll?.cancel()
        let interval = pace.interval
        poll = Task { [weak self] in
            // Slack lets the system wake us together with other work; the tightest pace keeps it short.
            try? await Task.sleep(for: interval, tolerance: interval / 10)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func updatePace() {
        let pace = NotchNeighborDetection.pace(apps: running.profiled.values, tracker: tracker, attentive: isAttentive)
        if pace != self.pace {
            log.debug("neighbor watch → \(pace) (every \(pace.interval))")
            self.pace = pace
        }
    }

    /// Reads the window list once and updates everything. Schedules the next look.
    public func refresh() {
        let clock = ContinuousClock()
        let began = clock.now
        let screens = Self.screens()
        let windows = Self.onScreenWindows()
        let result = NotchNeighborDetection.evaluate(windows: windows, screens: screens, apps: apps, ownBundleID: ownBundleID,
                                                     excludedPIDs: excludedPIDs)
        let events = tracker.update(result.sightings, running: running.pids, now: Date())
        let bar = NotchNeighborDetection.bar(windows: windows, screens: screens, apps: running.profiled)
        lastRefreshCost = clock.now - began
        refreshCount += 1

        report(events, exclusions: result.exclusions, apps: apps)
        let current = tracker.neighbors.values.sorted { ($0.name, $0.pid) < ($1.name, $1.pid) }
        if current != detected { detected = current }

        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let rect = bar.map { CGRect(x: $0.rect.minX, y: primaryHeight - $0.rect.maxY, width: $0.rect.width, height: $0.rect.height) }
        if rect != obstruction { obstruction = rect }
        if bar?.owner != obstructionOwner { obstructionOwner = bar?.owner }

        updatePace()
        schedule()
    }

    private func report(_ events: [NotchNeighborTracker.Event], exclusions: [NotchNeighborDetection.Exclusion],
                     apps: [pid_t: NotchNeighborDetection.App]) {
        for event in events {
            switch event {
            case .added(let neighbor, let window):
                let how = neighbor.profileName.map { "known notch app (\($0) profile)" } ?? "unknown app, window over the notch"
                let ignoredNote = ignored.contains(neighbor.bundleID) ? " · ignored at the user's request" : ""
                log.notice("notch neighbor: \(neighbor.name) [\(neighbor.bundleID), pid \(neighbor.pid)] · \(how) · "
                           + "\(Self.describe(window))\(neighbor.live ? " · counts while that window is up" : " · counts until it quits")"
                           + ignoredNote)
            case .removed(let neighbor, let reason):
                log.notice("notch neighbor gone: \(neighbor.name) (\(reason))")
            case .pending(let sighting):
                log.info("\(sighting.name) [\(sighting.bundleID)] put a window over the notch "
                         + "(\(Self.describe(sighting.window))) · confirming it stays")
            case .dropped(let sighting):
                log.info("\(sighting.name)'s window over the notch went away within \(Int(NotchNeighborTracker.confirmation * 1_000)) ms · not a neighbor")
            }
        }
        for exclusion in exclusions {
            let key = "\(exclusion.pid)|\(exclusion.reason)"
            guard !explained.contains(key) else { continue }
            explained.insert(key)
            let name = apps[exclusion.pid].map { "\($0.name) [\($0.bundleID ?? "no bundle ID")]" } ?? "pid \(exclusion.pid) (no app)"
            log.info("not a notch neighbor: \(name) · \(exclusion.reason) · \(Self.describe(exclusion.window))")
        }
        // Forget explanations for processes that are gone, so a relaunch is explained again.
        if explained.count > 64 {
            explained = explained.filter { key in
                key.split(separator: "|").first.flatMap { pid_t($0) }.map { apps[$0] != nil } ?? false
            }
        }
    }

    nonisolated public static func describe(_ window: WindowInfo) -> String {
        String(format: "%.0f×%.0f at %.0f,%.0f, layer %d", window.bounds.width, window.bounds.height,
               window.bounds.minX, window.bounds.minY, window.layer)
    }

    // MARK: - Window list

    public struct WindowInfo: Equatable, Sendable {
        public var ownerPID: pid_t
        public var layer: Int
        /// In CGWindow coordinates (origin top-left of the primary display).
        public var bounds: CGRect

        public init(ownerPID: pid_t, layer: Int, bounds: CGRect) {
            self.ownerPID = ownerPID
            self.layer = layer
            self.bounds = bounds
        }
    }

    public struct ScreenInfo: Equatable, Sendable {
        /// In CGWindow coordinates (origin top-left).
        public var frame: CGRect
        public var menuBarHeight: CGFloat
        /// The physical notch in CGWindow coordinates; `nil` on screens without one.
        public var notch: CGRect?

        public init(frame: CGRect, menuBarHeight: CGFloat, notch: CGRect? = nil) {
            self.frame = frame
            self.menuBarHeight = menuBarHeight
            self.notch = notch
        }

        /// Width of the stand-in notch that notch apps draw on screens without one.
        public static let virtualNotchWidth: CGFloat = 200

        /// Where a notch app sits on this screen: the notch, or the middle of the menu bar.
        public var notchArea: CGRect {
            notch ?? CGRect(x: frame.midX - Self.virtualNotchWidth / 2, y: frame.minY,
                            width: Self.virtualNotchWidth, height: max(menuBarHeight, 24))
        }
    }

    public static func onScreenWindows() -> [WindowInfo] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return list.compactMap { entry in
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  let dictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary) else { return nil }
            return WindowInfo(ownerPID: pid, layer: layer, bounds: bounds)
        }
    }

    /// The connected screens in CGWindow coordinates, with their notches.
    public static func screens() -> [ScreenInfo] {
        // CGWindow coordinates start at the top-left of the primary display; AppKit's at its bottom-left.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        func flip(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
        }
        return NSScreen.screens.map { screen in
            let geometry = NotchGeometry(screen: screen)
            return ScreenInfo(frame: flip(screen.frame),
                              menuBarHeight: max(screen.frame.maxY - screen.visibleFrame.maxY, screen.safeAreaInsets.top),
                              notch: geometry.hasNotch ? flip(geometry.notchRect) : nil)
        }
    }

    /// Bartender always has a thin menu-bar-height window. Top Shelf adds a much taller one above
    /// the menu bar level, pinned to the top of the screen, for its panel to open into.
    nonisolated public static func hasNotchPanel(_ windows: [WindowInfo], ownedBy pids: Set<pid_t>) -> Bool {
        windows.contains { pids.contains($0.ownerPID) && isTallCanvas($0, screenTop: 0) }
    }

    nonisolated public static func isTallCanvas(_ window: WindowInfo, screenTop: CGFloat) -> Bool {
        window.layer >= NotchNeighborDetection.menuBarLayer && window.layer < 1_000
            && window.bounds.minY <= screenTop + 1 && window.bounds.height >= 150
    }

    /// A menu bar manager's bar, when it's showing: a short window that starts right under a screen's
    /// menu bar and doesn't span the whole screen (Ice and Thaw also keep a full-width tint there).
    /// Returned in CGWindow coordinates.
    nonisolated public static func barBelowMenuBar(_ windows: [WindowInfo], ownedBy pids: Set<pid_t>,
                                                   screens: [ScreenInfo], layers: ClosedRange<Int> = 1...999) -> CGRect? {
        var found: CGRect?
        for window in windows where pids.contains(window.ownerPID) && layers.contains(window.layer) {
            let bounds = window.bounds
            guard (18...160).contains(bounds.height),
                  let screen = screens.first(where: { $0.frame.contains(CGPoint(x: bounds.midX, y: bounds.midY)) }),
                  bounds.width < screen.frame.width * 0.98 else { continue }
            let below = bounds.minY - screen.frame.minY
            guard below >= screen.menuBarHeight - 4, below <= screen.menuBarHeight + 24 else { continue }
            found = found.map { $0.union(bounds) } ?? bounds
        }
        return found
    }
}
