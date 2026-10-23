import CoreGraphics
import Foundation

/// What one app tells the others about its pill. It carries **no content**: no captions, no hosts, no levels, no
/// titles; only how much the app wants the notch and how big its pill would be.
///
/// Any local process can read announcements (distributed notifications are system-wide), so nothing in here may be
/// private. Decoding ignores unknown fields and defaults missing ones, so newer and older minors of protocol v1 work
/// together.
public struct NotchDockAnnouncement: Codable, Sendable, Equatable {
    /// Bundle ID; the user's order is keyed by it.
    public var appID: String
    public var pid: Int32
    /// Random per dock start; lets a `bye` from an old instance not remove a new one.
    public var instance: String
    /// `CGDirectDisplayID` of the screen the app's pill is on.
    public var displayID: UInt32
    public var want: NotchWant
    /// When `want` last changed (`NotchDock` sets it). Ties and the urgent hold use it.
    public var since: Date
    /// The pill's mode as drawn now (diagnostics; peers before 0.2.2 size the layout by it).
    public var mode: NotchMode
    /// The mode the pill rests in when nobody hovers it (`quiet`, `showing`, or `hidden`): the layout sizes passive
    /// slots by it and decides itself who is open, so a hover never feeds back through an announced mode. Missing
    /// (peers before 0.2.2): `mode`.
    public var restMode: NotchMode?
    public var sizes: NotchDockSizes
    /// The pointer is on this app's pill.
    public var hovered: Bool
    /// A menu from this app's pill is open.
    public var menuOpen: Bool
    /// While hovered: what of this app's pill was under the pointer when the hover began (screen coordinates). The
    /// layout keeps the open part covering it, so opening never moves the part out from under a still pointer.
    public var hoverHold: CGRect?
    /// While hovered: when the hover began. Of two apps hovered at once (a handover), the earlier stays open until it
    /// lets go, so the two are never open together.
    public var hoverSince: Date?
    public var switcherClaim: NotchSwitcherClaim?
    /// Sees a notch app that isn't one of ours (its neighbor monitor, peers excluded), or the user set "Always make
    /// room".
    public var seesStranger: Bool
    /// The menu bar manager's bar (Bartender, Ice…) this app sees under the menu bar, in screen coordinates.
    public var barRect: CGRect?
    /// Style names this app can draw. Unknown names are kept as strings so they round-trip.
    public var supportedStyles: [String]
    /// SF Symbol for Switcher dots.
    public var symbol: String

    public init(appID: String, pid: Int32, instance: String, displayID: UInt32 = 0, want: NotchWant = .none,
                since: Date = Date(timeIntervalSinceReferenceDate: 0), mode: NotchMode = .hidden,
                restMode: NotchMode? = nil, sizes: NotchDockSizes = .init(), hovered: Bool = false,
                menuOpen: Bool = false, hoverHold: CGRect? = nil, hoverSince: Date? = nil, switcherClaim: NotchSwitcherClaim? = nil, seesStranger: Bool = false, barRect: CGRect? = nil,
                supportedStyles: [String] = NotchSharingStyle.allCases.map(\.rawValue), symbol: String = "circle") {
        self.appID = appID
        self.pid = pid
        self.instance = instance
        self.displayID = displayID
        self.want = want
        self.since = since
        self.mode = mode
        self.restMode = restMode
        self.sizes = sizes
        self.hovered = hovered
        self.menuOpen = menuOpen
        self.hoverHold = hoverHold
        self.hoverSince = hoverSince
        self.switcherClaim = switcherClaim
        self.seesStranger = seesStranger
        self.barRect = barRect
        self.supportedStyles = supportedStyles
        self.symbol = symbol
    }

    /// Hovered or holding a menu open: the app is using its pill and keeps whatever it was granted.
    public var isSticky: Bool { hovered || menuOpen }

    /// The mode the layout sizes this app's passive slot by.
    public var rest: NotchMode { restMode ?? mode }

    public func supports(_ style: NotchSharingStyle) -> Bool {
        style == .priority || supportedStyles.contains(style.rawValue)
    }

    enum CodingKeys: String, CodingKey {
        case appID, pid, instance, displayID, want, since, mode, restMode, sizes, hovered, menuOpen, hoverHold,
             hoverSince, switcherClaim, seesStranger, barRect, supportedStyles, symbol
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appID = try c.decode(String.self, forKey: .appID)
        pid = try c.decode(Int32.self, forKey: .pid)
        instance = try c.decode(String.self, forKey: .instance)
        displayID = try c.decodeIfPresent(UInt32.self, forKey: .displayID) ?? 0
        want = (try? c.decodeIfPresent(String.self, forKey: .want)).flatMap { $0.map(NotchWant.init(name:)) } ?? .none
        since = try c.decodeIfPresent(Date.self, forKey: .since) ?? Date(timeIntervalSinceReferenceDate: 0)
        mode = (try? c.decodeIfPresent(String.self, forKey: .mode)).flatMap { $0.map(NotchMode.init(name:)) } ?? .quiet
        restMode = (try? c.decodeIfPresent(String.self, forKey: .restMode)).flatMap { $0.map(NotchMode.init(name:)) }
        sizes = (try? c.decodeIfPresent(NotchDockSizes.self, forKey: .sizes)) ?? .init()
        hovered = try c.decodeIfPresent(Bool.self, forKey: .hovered) ?? false
        menuOpen = try c.decodeIfPresent(Bool.self, forKey: .menuOpen) ?? false
        hoverHold = try? c.decodeIfPresent(CGRect.self, forKey: .hoverHold)
        hoverSince = try? c.decodeIfPresent(Date.self, forKey: .hoverSince)
        switcherClaim = try? c.decodeIfPresent(NotchSwitcherClaim.self, forKey: .switcherClaim)
        seesStranger = try c.decodeIfPresent(Bool.self, forKey: .seesStranger) ?? false
        barRect = try? c.decodeIfPresent(CGRect.self, forKey: .barRect)
        supportedStyles = try c.decodeIfPresent([String].self, forKey: .supportedStyles) ?? []
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "circle"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(appID, forKey: .appID)
        try c.encode(pid, forKey: .pid)
        try c.encode(instance, forKey: .instance)
        try c.encode(displayID, forKey: .displayID)
        try c.encode(want.name, forKey: .want)
        try c.encode(since, forKey: .since)
        try c.encode(mode.name, forKey: .mode)
        try c.encodeIfPresent(restMode?.name, forKey: .restMode)
        try c.encode(sizes, forKey: .sizes)
        try c.encode(hovered, forKey: .hovered)
        try c.encode(menuOpen, forKey: .menuOpen)
        try c.encodeIfPresent(hoverHold, forKey: .hoverHold)
        try c.encodeIfPresent(hoverSince, forKey: .hoverSince)
        try c.encodeIfPresent(switcherClaim, forKey: .switcherClaim)
        try c.encode(seesStranger, forKey: .seesStranger)
        try c.encodeIfPresent(barRect, forKey: .barRect)
        try c.encode(supportedStyles, forKey: .supportedStyles)
        try c.encode(symbol, forKey: .symbol)
    }
}
