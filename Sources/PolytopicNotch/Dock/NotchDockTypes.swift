import AppKit

// The dock's small value types. The dock lets apps that use this package share the notch: each app announces what it wants
// (no content), every app runs the same layout over the same announcements, and each draws only its own slot.

/// How the docked apps share the notch. One setting for all docked apps (`NotchDockSettings`).
/// Raw values are stored in the shared settings and sent in announcements: never rename them.
public enum NotchSharingStyle: String, Sendable, CaseIterable, Codable {
    /// One app at a time: the one that wants it most.
    case priority
    /// Priority, plus a dot for each docked app in the open pill; clicking one hands the notch over.
    case switcher
    /// Side by side: each app gets an ear of the notch, and what they show hangs below in equal parts.
    case split
    /// Stacked: one black pill, each app's part below the one before.
    case merged

    /// Unknown or missing values (a newer app wrote a style this one doesn't know) read as Priority.
    public init(stored: String?) {
        self = stored.flatMap(Self.init(rawValue:)) ?? .priority
    }

    public init(from decoder: Decoder) throws {
        self.init(stored: try? decoder.singleValueContainer().decode(String.self))
    }

    /// The Settings picker's name.
    public var title: String {
        switch self {
        case .priority: "Priority"
        case .switcher: "Switcher"
        case .split: "Split"
        case .merged: "Merged"
        }
    }

    /// One plain line for the Settings picker.
    public var explanation: String {
        switch self {
        case .priority: "The app with the most to show gets the notch; the others wait."
        case .switcher: "Like Priority, with a dot for each app when you hover; click one to switch."
        case .split: "Each app keeps a corner of the notch, and what they show sits side by side."
        case .merged: "One pill, with each app's part stacked below the one before."
        }
    }
}

/// How long an unanswered urgent question keeps the notch from the other apps.
public enum NotchUrgentHold: Sendable, Equatable, Hashable {
    case seconds(TimeInterval)
    case untilAnswered

    public static let standard = NotchUrgentHold.seconds(30)

    /// Whether an urgent want that started at `since` still holds the notch at `now`.
    public func holds(since: Date, now: Date) -> Bool {
        switch self {
        case .untilAnswered: true
        case .seconds(let s): now.timeIntervalSince(since) < s
        }
    }

    /// When the hold ends, or nil if it never does.
    public func deadline(since: Date) -> Date? {
        switch self {
        case .untilAnswered: nil
        case .seconds(let s): since.addingTimeInterval(s)
        }
    }
}

extension NotchWant {
    /// The name sent in announcements (`none`, `quiet`, `notice`, `live`, `urgent`).
    public var name: String {
        switch self {
        case .none: "none"
        case .quiet: "quiet"
        case .notice: "notice"
        case .live: "live"
        case .urgent: "urgent"
        }
    }

    /// Unknown names (from a newer app) read as `notice`: visible, but never above a live session or a question.
    public init(name: String) {
        self = Self.allCases.first { $0.name == name } ?? .notice
    }
}

extension NotchMode {
    /// The modes an app announces sizes for.
    public static let announced: [NotchMode] = [.quiet, .showing, .asking, .expanded]

    /// The name sent in announcements.
    public var name: String {
        switch self {
        case .hidden: "hidden"
        case .quiet: "quiet"
        case .showing: "showing"
        case .expanded: "expanded"
        case .asking: "asking"
        }
    }

    /// Unknown names (from a newer app) read as `quiet`.
    public init(name: String) {
        self = [NotchMode.hidden, .quiet, .showing, .expanded, .asking].first { $0.name == name } ?? .quiet
    }
}

/// A size an app announces for one mode: the pill's width and the height of its body *below* the band (the notch,
/// or a capsule's header row). A quiet pill's body height is 0.
public struct NotchDockSize: Codable, Sendable, Equatable {
    public var width: Double
    public var bodyHeight: Double

    public init(width: Double, bodyHeight: Double) {
        self.width = width
        self.bodyHeight = bodyHeight
    }
}

/// Announced sizes per mode. Missing modes fall back to the quiet ears (or a quiet capsule). Unknown keys are ignored.
public struct NotchDockSizes: Codable, Sendable, Equatable {
    public var quiet: NotchDockSize?
    public var showing: NotchDockSize?
    public var asking: NotchDockSize?
    public var expanded: NotchDockSize?

    public init(quiet: NotchDockSize? = nil, showing: NotchDockSize? = nil, asking: NotchDockSize? = nil,
                expanded: NotchDockSize? = nil) {
        self.quiet = quiet
        self.showing = showing
        self.asking = asking
        self.expanded = expanded
    }

    public subscript(mode: NotchMode) -> NotchDockSize? {
        get {
            switch mode {
            case .hidden: nil
            case .quiet: quiet
            case .showing: showing
            case .asking: asking
            case .expanded: expanded
            }
        }
        set {
            switch mode {
            case .hidden: break
            case .quiet: quiet = newValue
            case .showing: showing = newValue
            case .asking: asking = newValue
            case .expanded: expanded = newValue
            }
        }
    }
}

/// A Switcher dot click: "until the pointer leaves the dock, the notch goes to `pid`, open". The latest claim wins; the claimer
/// clears it when the pointer leaves the dock (`NotchDock.endHoverSession()`).
public struct NotchSwitcherClaim: Codable, Sendable, Equatable, Hashable {
    public var pid: Int32
    public var at: Date

    public init(pid: Int32, at: Date) {
        self.pid = pid
        self.at = at
    }
}

/// One dot in the Switcher row of the open pill.
public struct NotchSwitcherDot: Sendable, Equatable, Hashable {
    public var pid: Int32
    public var appID: String
    public var symbol: String
    /// The app that has the notch now.
    public var isCurrent: Bool

    public init(pid: Int32, appID: String, symbol: String, isCurrent: Bool) {
        self.pid = pid
        self.appID = appID
        self.symbol = symbol
        self.isCurrent = isCurrent
    }
}

/// The screen as the dock's layout sees it. Every docked app on a display builds the same value, so they all solve
/// the same layout.
public struct NotchDockScreen: Sendable, Equatable {
    /// `CGDirectDisplayID` (`NSScreenNumber`).
    public var displayID: UInt32
    /// Screen frame in global AppKit coordinates (origin bottom-left).
    public var screenFrame: CGRect
    /// The physical notch, or nil on screens without one.
    public var notchRect: CGRect?
    public var menuBarHeight: CGFloat
    /// Backing scale; rects are snapped to its pixel grid so the joints between windows line up.
    public var scale: CGFloat

    public init(displayID: UInt32, screenFrame: CGRect, notchRect: CGRect?, menuBarHeight: CGFloat, scale: CGFloat) {
        self.displayID = displayID
        self.screenFrame = screenFrame
        self.notchRect = notchRect
        self.menuBarHeight = menuBarHeight
        self.scale = scale
    }

    /// From the library's geometry (its own placement and drop are ignored: the dock decides those).
    public init(geometry: NotchGeometry, displayID: UInt32, scale: CGFloat) {
        self.init(displayID: displayID, screenFrame: geometry.screenFrame,
                  notchRect: geometry.hasNotch ? geometry.notchRect : nil,
                  menuBarHeight: geometry.menuBarHeight, scale: scale)
    }

    @MainActor
    public init(screen: NSScreen) {
        self.init(geometry: NotchGeometry(screen: screen), displayID: Self.displayID(of: screen),
                  scale: screen.backingScaleFactor)
    }

    @MainActor
    public static func displayID(of screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    public var centerX: CGFloat { notchRect?.midX ?? screenFrame.midX }
}

/// The dock's measurements, derived from the pill's own (`NotchMetrics`, `NotchGeometry`, `NotchOutline`).
public struct NotchDockMetrics: Sendable, Equatable {
    /// One quiet ear beside the notch (`NotchMetrics.ear`).
    public var ear: CGFloat
    /// Between the menu bar and a capsule on screens without a notch (`NotchGeometry.barGap`).
    public var barGap: CGFloat
    /// Between the notch (or a stranger's bar) and the pill when the notch is shared (`NotchGeometry.sharedGap`).
    public var sharedGap: CGFloat
    /// The attached pill's outward flare at the top edge (`NotchMetrics.flare`). Merged lower slots are the top
    /// slot's body width: shared width − 2 × flare.
    public var flare: CGFloat
    /// Split: the slit between two bodies, and between the two wings (hidden inside the notch).
    public var splitSlit: CGFloat = 6
    /// Split: a quiet ear's rounded bottom corner; a quiet wing's neck stops this far above the ear's bottom.
    public var earCornerRadius: CGFloat = 10
    /// Split: the concave shoulder where a wing's neck meets its body (`NotchOutline.shoulder`).
    public var shoulder: CGFloat
    /// Window levels: the notch is ours (`.mainMenu + 3`), and the pointer is on the dock (below pop-up menus).
    public var normalLevel = 27
    public var hoveredLevel = 100
    /// Merged: the smallest visible height of a lower slot (a quiet app's row).
    public var minLowerSlotHeight: CGFloat = 24
    /// The header row of a glass capsule on screens without a notch (`NotchMetrics.menuBarBand`).
    public var capsuleBand: CGFloat
    /// The gap at the top of a capsule hanging below a stranger's notch (`NotchMetrics.belowNotchBand`).
    public var belowNotchBand: CGFloat
    /// A capsule's width when an app announced none (`NotchMetrics.menuBarQuiet`).
    public var capsuleWidth: CGFloat
    /// Switcher: the dots' row above an open body (`NotchMetrics.switcherRow`). The layout adds it to the open slot;
    /// apps don't announce it.
    public var switcherRow: CGFloat
    /// Between separate capsules (Split side by side, Merged stacked).
    public var capsuleGap: CGFloat = 6
    /// Nothing is laid out closer than this to the screen's sides.
    public var screenMargin: CGFloat = 16

    public init(_ metrics: NotchMetrics = .standard) {
        ear = metrics.ear
        barGap = NotchGeometry.barGap
        sharedGap = NotchGeometry.sharedGap
        flare = metrics.flare
        shoulder = NotchOutline.shoulder
        capsuleBand = metrics.menuBarBand
        belowNotchBand = metrics.belowNotchBand
        capsuleWidth = metrics.menuBarQuiet.width
        switcherRow = metrics.switcherRow
    }

    public static let standard = NotchDockMetrics()

    /// The band at the top of a pill in this placement, for a screen with this notch.
    public func band(_ placement: NotchGeometry.Placement, notchHeight: CGFloat) -> CGFloat {
        switch placement {
        case .notch: notchHeight
        case .menuBar: capsuleBand
        case .belowNotch: belowNotchBand
        }
    }
}

extension NotchViewModel {
    /// The sizes this pill announces to the dock: each mode's width, and its height below the band, where the pill
    /// hangs now. Without the Switcher dots' row: the layout adds that itself where it gives the dots
    /// (`NotchDockLayout.whole`), so the slot has room for it from the first layout.
    public var dockSizes: NotchDockSizes {
        let band = NotchDockMetrics(metrics).band(placement, notchHeight: geometry.notchSize.height)
        var sizes = NotchDockSizes()
        for mode in NotchMode.announced {
            let size = size(for: mode)
            let row = mode == .expanded ? switcherRowHeight : 0
            sizes[mode] = NotchDockSize(width: Double(size.width), bodyHeight: Double(max(0, size.height - band - row)))
        }
        return sizes
    }
}
