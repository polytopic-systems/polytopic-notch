import CoreGraphics
import Foundation

// MARK: - Who counts

/// The rules, as pure functions over a window list.
public enum NotchNeighborDetection {
    public typealias WindowInfo = NotchNeighborMonitor.WindowInfo
    public typealias ScreenInfo = NotchNeighborMonitor.ScreenInfo

    /// `kCGMainMenuWindowLevel`. Notch apps sit here or above so they can cover the menu bar.
    public static let menuBarLayer = 24
    /// Above this an unknown window is an overlay (accessibility, cursor, screen tools), not a notch app.
    /// DynamicNotchKit apps and Textream use the screen-saver level, 1000.
    public static let highestNotchLayer = 1_500
    /// How far either side of the notch a known app's window may sit and still count (TickerNotch-style
    /// content beside the notch collides with the pill's ears and its content).
    public static let besideReach: CGFloat = 280

    public struct App: Equatable, Sendable {
        public var pid: pid_t
        public var bundleID: String?
        public var name: String

        public init(pid: pid_t, bundleID: String?, name: String) {
            self.pid = pid
            self.bundleID = bundleID
            self.name = name
        }
    }

    public struct Sighting: Equatable, Sendable {
        public var pid: pid_t
        public var bundleID: String
        public var name: String
        /// `nil` for an app recognised by the general rule.
        public var profile: NotchNeighborProfile?
        public var window: WindowInfo

        public init(pid: pid_t, bundleID: String, name: String, profile: NotchNeighborProfile?, window: WindowInfo) {
            self.pid = pid
            self.bundleID = bundleID
            self.name = name
            self.profile = profile
            self.window = window
        }
    }

    public struct Exclusion: Equatable, Sendable {
        public var pid: pid_t
        public var reason: String
        public var window: WindowInfo
    }

    public struct Result: Equatable, Sendable {
        public var sightings: [Sighting] = []
        public var exclusions: [Exclusion] = []
    }

    /// Which processes have a window on the notch right now, and why the other windows over it don't count.
    /// Windows of `excludedPIDs` are skipped (docked peers).
    public static func evaluate(windows: [WindowInfo], screens: [ScreenInfo], apps: [pid_t: App],
                                ownBundleID: String?, excludedPIDs: Set<pid_t> = []) -> Result {
        var result = Result()
        var seen = Set<pid_t>()
        for window in windows where window.layer >= menuBarLayer && !seen.contains(window.ownerPID) {
            let pid = window.ownerPID
            if excludedPIDs.contains(pid) {
                if covers(window, screens: screens) != nil {
                    seen.insert(pid)
                    result.exclusions.append(Exclusion(pid: pid, reason: "excluded (a docked app)", window: window))
                }
                continue
            }
            let app = apps[pid]
            let profile = app?.bundleID.flatMap(NotchNeighborProfile.profile(for:))

            // Known apps: their own rule, and boxes and strips are fine (bounds lie for many of them).
            if let app, let bundleID = app.bundleID, let profile {
                switch profile.notchWindow {
                case .none:
                    if covers(window, screens: screens) != nil {
                        result.exclusions.append(Exclusion(pid: pid, reason: profile.role == .cosmetic
                            ? "\(profile.name) only decorates the notch" : "\(profile.name) is a menu bar manager",
                            window: window))
                    }
                case .overNotch:
                    if touches(window, screens: screens) != nil {
                        seen.insert(pid)
                        result.sightings.append(Sighting(pid: pid, bundleID: bundleID, name: profile.name, profile: profile, window: window))
                    }
                case .tallCanvas:
                    if let screen = touches(window, screens: screens),
                       NotchNeighborMonitor.isTallCanvas(window, screenTop: screen.frame.minY) {
                        seen.insert(pid)
                        result.sightings.append(Sighting(pid: pid, bundleID: bundleID, name: profile.name, profile: profile, window: window))
                    }
                }
                continue
            }

            // Everyone else: a window at menu-bar level or above that hangs from the top edge over the notch.
            guard let screen = covers(window, screens: screens) else { continue }
            guard let app else {
                result.exclusions.append(Exclusion(pid: pid, reason: "system surface (no app; e.g. the menu bar)", window: window))
                continue
            }
            guard let bundleID = app.bundleID else {
                result.exclusions.append(Exclusion(pid: pid, reason: "not an app bundle", window: window))
                continue
            }
            if bundleID == ownBundleID {
                result.exclusions.append(Exclusion(pid: pid, reason: "another copy of this app", window: window))
                continue
            }
            if bundleID.hasPrefix("com.apple.") {
                result.exclusions.append(Exclusion(pid: pid, reason: "system surface", window: window))
                continue
            }
            if window.layer > highestNotchLayer {
                result.exclusions.append(Exclusion(pid: pid, reason: "overlay level (above \(highestNotchLayer))", window: window))
                continue
            }
            if window.bounds.width >= screen.frame.width * 0.95 {
                result.exclusions.append(Exclusion(pid: pid, reason: "full-width strip or overlay", window: window))
                continue
            }
            if window.bounds.minY > screen.frame.minY + 2 {
                result.exclusions.append(Exclusion(pid: pid, reason: "not attached to the top edge", window: window))
                continue
            }
            seen.insert(pid)
            result.sightings.append(Sighting(pid: pid, bundleID: bundleID, name: app.name, profile: nil, window: window))
        }
        return result
    }

    /// The screen whose notch area this window covers properly: it overlaps the notch (or the middle of
    /// the menu bar) by a real amount and spans its centre. Edge-touching popovers and status items don't.
    public static func covers(_ window: WindowInfo, screens: [ScreenInfo]) -> ScreenInfo? {
        guard window.layer >= menuBarLayer, window.bounds.width > 0, window.bounds.height > 0 else { return nil }
        return screens.first { screen in
            let area = screen.notchArea
            let overlap = window.bounds.intersection(area)
            guard !overlap.isNull, overlap.height >= min(4, area.height),
                  overlap.width >= min(area.width / 2, 60) else { return false }
            return window.bounds.minX <= area.midX && window.bounds.maxX >= area.midX
        }
    }

    /// Looser, for known notch apps: any window in the band across the top of the screen at and beside the notch.
    public static func touches(_ window: WindowInfo, screens: [ScreenInfo]) -> ScreenInfo? {
        guard window.layer >= menuBarLayer, window.bounds.width > 0, window.bounds.height > 0 else { return nil }
        return screens.first { screen in
            let band = screen.notchArea.insetBy(dx: -besideReach, dy: 0)
            let overlap = window.bounds.intersection(band)
            return !overlap.isNull && overlap.height >= min(4, band.height) && overlap.width >= 8
        }
    }

    /// The bar a running menu bar manager is showing under the menu bar, if any (CGWindow coordinates).
    public static func bar(windows: [WindowInfo], screens: [ScreenInfo], apps: [pid_t: App]) -> (rect: CGRect, owner: String)? {
        var found: (rect: CGRect, owner: String)?
        var byProfile: [String: (profile: NotchNeighborProfile, pids: Set<pid_t>)] = [:]
        for app in apps.values {
            guard let profile = app.bundleID.flatMap(NotchNeighborProfile.profile(for:)), profile.barLayers != nil else { continue }
            byProfile[profile.name, default: (profile, [])].pids.insert(app.pid)
        }
        for (name, entry) in byProfile.sorted(by: { $0.key < $1.key }) {
            guard let layers = entry.profile.barLayers,
                  let rect = NotchNeighborMonitor.barBelowMenuBar(windows, ownedBy: entry.pids, screens: screens, layers: layers)
            else { continue }
            found = found.map { ($0.rect.union(rect), $0.owner + " + " + name) } ?? (rect, name)
        }
        return found
    }

    /// How closely to keep watching, given what's running and whether anything of ours is showing.
    /// Confirming an unknown app's window is quick and one-off, so it happens either way.
    public static func pace(apps: some Sequence<App>, tracker: NotchNeighborTracker, attentive: Bool = true) -> NotchNeighborMonitor.Pace {
        if tracker.isConfirming { return .confirming }
        guard attentive else { return .idle }
        var pace = NotchNeighborMonitor.Pace.idle
        for app in apps {
            guard let profile = app.bundleID.flatMap(NotchNeighborProfile.profile(for:)) else { continue }
            if profile.barLayers != nil { return .bar }
            switch profile.notchWindow {
            case .none: break
            // Top Shelf can be switched off while Bartender runs, so it's always watched.
            case .tallCanvas: pace = .watching
            case .overNotch: if !tracker.knows(app.pid) { pace = .watching }
            }
        }
        return pace
    }
}

/// The running apps the neighbor rules look at, kept current from launch and quit events rather than
/// re-reading every app (and its LaunchServices state) each time anything launches.
public struct NotchRunningApps: Equatable, Sendable {
    public typealias App = NotchNeighborDetection.App

    public private(set) var apps: [pid_t: App] = [:]
    /// The running apps that have a profile, for the bar rule and the pace.
    public private(set) var profiled: [pid_t: App] = [:]
    public var pids: Set<pid_t> { Set(apps.keys) }

    public init(_ apps: [App] = []) {
        apply(launched: apps, quit: [])
    }

    public mutating func apply(launched: [App], quit: [App]) {
        for app in quit {
            apps[app.pid] = nil
            profiled[app.pid] = nil
        }
        for app in launched where apps[app.pid] == nil {
            apps[app.pid] = app
            if app.bundleID.flatMap(NotchNeighborProfile.profile(for:)) != nil { profiled[app.pid] = app }
        }
    }
}

/// Remembers who counts as a neighbor between looks at the window list.
///
/// Event-driven islands appear when something needs attention and vanish again, so presence is sticky:
/// once an app has shown a window on the notch it counts until it quits. Otherwise the pill would hop
/// between "on the notch" and "below it" every time one blinked. The exceptions:
/// - Bartender's Top Shelf is a permanent canvas that the user can switch off; it counts only while it's up.
/// - An unknown app must still be there on a second look (`confirmation`), so a window passing over
///   the notch for a moment doesn't move the pill until the app quits.
public struct NotchNeighborTracker: Sendable {
    public struct Neighbor: Equatable, Sendable, Identifiable {
        public var pid: pid_t
        public var bundleID: String
        public var name: String
        /// The profile it was recognised by; `nil` when the general rule found it.
        public var profileName: String?
        /// Counts only while its notch window is showing.
        public var live: Bool
        public var id: pid_t { pid }

        public init(pid: pid_t, bundleID: String, name: String, profileName: String?, live: Bool) {
            self.pid = pid
            self.bundleID = bundleID
            self.name = name
            self.profileName = profileName
            self.live = live
        }
    }

    public enum Event: Equatable, Sendable {
        case added(Neighbor, window: NotchNeighborMonitor.WindowInfo)
        case removed(Neighbor, reason: String)
        case pending(NotchNeighborDetection.Sighting)
        case dropped(NotchNeighborDetection.Sighting)
    }

    /// How long an unknown app's window must stay over the notch before it counts.
    public static let confirmation: TimeInterval = 0.3

    public private(set) var neighbors: [pid_t: Neighbor] = [:]
    private var pending: [pid_t: (since: Date, sighting: NotchNeighborDetection.Sighting)] = [:]

    public init() {}

    public var isConfirming: Bool { !pending.isEmpty }
    public func knows(_ pid: pid_t) -> Bool { neighbors[pid] != nil || pending[pid] != nil }

    /// Drops what's known about a process at once (sticky presence included). Returns the neighbor it was, if any.
    ///
    /// A process that turns out to be a docked peer (or leaves the dock) is forgotten this way.
    @discardableResult
    public mutating func forget(pid: pid_t) -> Neighbor? {
        pending[pid] = nil
        return neighbors.removeValue(forKey: pid)
    }

    public mutating func update(_ sightings: [NotchNeighborDetection.Sighting], running: Set<pid_t>, now: Date) -> [Event] {
        var events: [Event] = []
        let sighted = Dictionary(sightings.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        for (pid, neighbor) in neighbors.sorted(by: { $0.key < $1.key }) {
            if !running.contains(pid) {
                neighbors[pid] = nil
                events.append(.removed(neighbor, reason: "quit"))
            } else if neighbor.live && sighted[pid] == nil {
                neighbors[pid] = nil
                events.append(.removed(neighbor, reason: "its notch panel closed"))
            }
        }
        for (pid, entry) in pending.sorted(by: { $0.key < $1.key }) where sighted[pid] == nil {
            pending[pid] = nil
            if running.contains(pid) { events.append(.dropped(entry.sighting)) }
        }
        for sighting in sightings where neighbors[sighting.pid] == nil {
            if let profile = sighting.profile {
                let neighbor = Neighbor(pid: sighting.pid, bundleID: sighting.bundleID, name: sighting.name,
                                        profileName: profile.name, live: profile.notchWindow == .tallCanvas)
                neighbors[sighting.pid] = neighbor
                events.append(.added(neighbor, window: sighting.window))
            } else if let entry = pending[sighting.pid] {
                guard now.timeIntervalSince(entry.since) >= Self.confirmation else { continue }
                pending[sighting.pid] = nil
                let neighbor = Neighbor(pid: sighting.pid, bundleID: sighting.bundleID, name: sighting.name,
                                        profileName: nil, live: false)
                neighbors[sighting.pid] = neighbor
                events.append(.added(neighbor, window: sighting.window))
            } else {
                pending[sighting.pid] = (now, sighting)
                events.append(.pending(sighting))
            }
        }
        return events
    }
}
