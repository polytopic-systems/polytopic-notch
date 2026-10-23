import AppKit
import Observation
import SwiftUI

public enum NotchMode: Equatable, Sendable {
    /// Content is off: nothing visible beyond the physical notch.
    case hidden
    /// Active but quiet: level meter and status dot beside the notch (or a slim line under it).
    case quiet
    /// Something to show: the content's `showing` body drops below the notch.
    case showing
    /// Pointer on the notch (or a menu from the pill open): the content's `expanded` body.
    case expanded
    /// A question waits for the user (`NotchContent.prompt`): the pill grows around it, whether or not the pointer
    /// is there, until it is answered or put off.
    case asking
}

/// The pill's fixed measurements. Both apps use `standard`; the dock's measurements derive from it
/// (`NotchDockMetrics`).
public struct NotchMetrics: Equatable, Sendable {
    /// Width of the area beside the notch used for the meter and the status dot.
    public var ear: CGFloat = 40
    /// The panel is this big; the pill animates inside it.
    public var panelSize = CGSize(width: 680, height: 420)
    /// Padding inside the notch shape so content clears its curved sides.
    public var pillInset: CGFloat = 6
    /// The attached pill's outward flare where it meets the top edge of the screen.
    public var flare: CGFloat = 6
    public var showingWidth: CGFloat = 500
    /// The glass bar on screens without a notch is this much wider while showing (unless the body sets a width).
    public var menuBarShowingExtra: CGFloat = 20
    public var expandedWidth: CGFloat = 560
    public var expandedBodyHeight: CGFloat = 300
    public var askingWidth: CGFloat = 540
    /// Room below a question's view.
    public var askingPadding: CGFloat = 6
    /// The quiet line below a shared notch (and under ours), and its bigger busy version.
    public var quietLine = CGSize(width: 84, height: 5)
    public var busyLine = CGSize(width: 180, height: 7)
    /// The glass bar on screens without a notch while quiet.
    public var menuBarQuiet = CGSize(width: 190, height: 30)
    /// The band at the top of the glass bar, and the gap at the top of the pill below a shared notch.
    public var menuBarBand: CGFloat = 30
    public var belowNotchBand: CGFloat = 10
    /// The Switcher dots' own row above an open body, where the band can't hold them (`switcherRowHeight`): 18 pt
    /// dots with 4 pt above and below.
    public var switcherRow: CGFloat = 26
    /// Text inside a body keeps this far from the pill's sides (`bodyTextWidth`).
    public var textSidePadding: CGFloat = 18
    public var textHeadroom: CGFloat = 8
    public var textBottomPadding: CGFloat = 12

    public init() {}

    public static let standard = NotchMetrics()
}

/// One spring for every size and mode change, so pills (and later, docked slots) move together.
public enum NotchSpring {
    public static let response = 0.42
    public static let dampingFraction = 0.8
    public static var animation: Animation { .spring(response: response, dampingFraction: dampingFraction) }
}

/// Text metrics for a body's text box. The box is a fixed height for the font size, so text never rises into
/// the notch band (text once slid up behind the notch).
public struct NotchTextStyle: Equatable, Sendable {
    public var size: CGFloat
    public var weight: NSFont.Weight = .medium

    public init(size: CGFloat, weight: NSFont.Weight = .medium) {
        self.size = size
        self.weight = weight
    }

    public var font: NSFont { .systemFont(ofSize: size, weight: weight) }
    public var swiftUIFont: Font { Font(font as CTFont) }
    /// One line of this font (ascender, descender and leading), rounded up to whole points.
    public var lineHeight: CGFloat {
        let font = font
        return ceil(font.ascender - font.descender + font.leading)
    }
}

/// The pill's state: where it hangs, which mode it's in, how big it is and where the pointer counts. Bodies read
/// it from the environment (`@Environment(NotchViewModel.self)`) for the placement, `isDark` and `bodyTextWidth`.
@MainActor
@Observable
public final class NotchViewModel {
    public let content: NotchContent
    public let settings: any NotchSettingsStore
    public var theme: NotchTheme
    public let metrics: NotchMetrics
    public var geometry: NotchGeometry
    /// This app's share of the notch: `solo` without a dock, otherwise what the dock's layout gave this app.
    public var slot: NotchSlot = .solo
    /// With a dock, the panel's fixed frame in screen coordinates: docked slots are drawn at their place inside it.
    /// `nil`: solo, the pill hangs top-centre in the panel as it always has.
    public var dockCanvas: CGRect?
    /// Switcher: a dot in this pill was clicked (the controller hands the notch to that app).
    @ObservationIgnored public var onSwitcherDot: (@MainActor (Int32) -> Void)?
    public var isHovering = false
    /// Stepping aside so the app sharing the notch can show its own panel (Option-hover).
    public var isYielding = false
    /// A pop-up menu from the pill is open (`NotchMenuButton`). Keeps the pill expanded while the pointer is on the
    /// menu, outside the pill; the panel controller leaves hover alone until it closes.
    public var isMenuOpen = false
    /// Called when the pill's pop-up menu has closed, so hover is looked at again.
    @ObservationIgnored public var onMenuClosed: (@MainActor () -> Void)?
    /// Shows a menu and returns once it has closed. Tests replace it so no real menu opens.
    @ObservationIgnored public var presentMenu: @MainActor (NSMenu, NSView?) -> Void = { menu, view in
        if let view {
            // Below the control's lower-left corner.
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : -4), in: view)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    public init(content: NotchContent, settings: any NotchSettingsStore, geometry: NotchGeometry,
                theme: NotchTheme = .standard, metrics: NotchMetrics = .standard) {
        self.content = content
        self.settings = settings
        self.geometry = geometry
        self.theme = theme
        self.metrics = metrics
    }

    /// Pins the mode, for render tests and previews.
    public var previewMode: NotchMode?

    public var mode: NotchMode {
        if let previewMode { return previewMode }
        if isYielding { return .hidden }
        if canAsk { return .asking }
        if dockCanvas != nil {
            // Docked: the dock's layout says who is open (the hovered app, or a Switcher dot's target). Two apps
            // hovered for a moment during a handover never both open.
            return slot.isOpen && slot.mayExpand ? .expanded : restMode
        }
        if (isHovering || isMenuOpen) && slot.mayExpand { return .expanded }
        return restMode
    }

    /// The mode without hover: what the content shows on its own.
    public var restMode: NotchMode {
        isYielding ? .hidden : Self.mode(for: content.status)
    }

    /// Docked, while hovered: this pill's part that was under the pointer when the hover began (announced, so the
    /// layout keeps the open part over it).
    public var hoverHold: CGRect?
    /// Docked, while hovered: when the hover began (announced; the earlier of two hovered apps stays open).
    public var hoverSince: Date?

    /// What each content status looks like at the notch.
    public static func mode(for status: NotchContent.Status) -> NotchMode {
        switch status {
        case .off: .hidden
        case .quiet: .quiet
        case .showing, .attention: .showing
        }
    }

    /// Questions go in the pill where it hangs from a notch (ours or shared). Without a notch the floating window
    /// asks instead (`NotchPromptWindowController`), so a question never hides in a bar below the menu bar.
    public var canAsk: Bool { content.prompt != nil && placement != .menuBar && slot.mayAsk }

    /// The theme's attention colour instead of the accent: the content wants attention.
    public var needsAttention: Bool { content.status == .attention }

    public var placement: NotchGeometry.Placement { geometry.placement }

    /// The notch-attached and below-notch looks are black like the notch; the menu bar look is glass.
    public var isDark: Bool { placement != .menuBar }

    /// Switcher: the open pill shows a dot for each docked app, in a row of their own above the body.
    public var showsSwitcherDots: Bool { mode == .expanded && hasSwitcherDots }

    /// The dock gave this pill Switcher dots (two or more apps share the notch in the Switcher style).
    var hasSwitcherDots: Bool { slot.switcherDots.count > 1 }

    /// The height of the Switcher dots' own row between the band and the expanded body: `metrics.switcherRow` while the
    /// dock gives this pill dots (two or more apps docked in Switcher), in every placement, otherwise 0. The dots sit in
    /// it centred on the pill (under the notch), never in the band and never over the body. Counted in
    /// `size(for: .expanded)`; the dock's layout adds the same row to the open slot.
    public var switcherRowHeight: CGFloat { hasSwitcherDots ? metrics.switcherRow : 0 }

    public var topBandHeight: CGFloat {
        switch placement {
        case .notch: notchTop(for: mode)
        case .menuBar: metrics.menuBarBand
        case .belowNotch: metrics.belowNotchBand
        }
    }

    // MARK: Attached to the notch

    /// The "Keep the menu bar clear" shape applies to this mode: inside the menu bar the black stays
    /// notch-wide, and the content starts below the bar.
    public func keepsMenuBarClear(_ mode: NotchMode) -> Bool {
        placement == .notch && settings.notch.pillShape == .clearMenuBar
            && (mode == .showing || mode == .expanded || mode == .asking)
    }

    /// The quiet indicator is a slim line under the notch instead of a dot and meter beside it.
    public var indicatorUnderNotch: Bool { placement == .notch && settings.notch.indicator == .underNotch }

    /// How far down the menu bar reaches on this screen (at least the notch).
    public var menuBarDepth: CGFloat { max(geometry.notchSize.height, geometry.menuBarHeight) }

    /// Height of the band at the top of the attached pill before its content starts.
    public func notchTop(for mode: NotchMode) -> CGFloat {
        keepsMenuBarClear(mode) ? menuBarDepth + NotchOutline.shoulder : geometry.notchSize.height
    }

    /// The attached pill's outline for a mode.
    public func attachedShape(for mode: NotchMode) -> NotchOutline {
        let clear = keepsMenuBarClear(mode)
        let bottom: CGFloat = switch mode {
        case .hidden: 8
        case .quiet: 10
        case .showing: content.showing?.bottomRadius ?? 20
        case .expanded, .asking: 26
        }
        return NotchOutline(topRadius: clear ? 0 : metrics.flare, bottomRadius: bottom,
                            neckWidth: clear ? geometry.notchSize.width : size(for: mode).width,
                            neckDepth: clear ? menuBarDepth : 0)
    }

    // MARK: Sizes

    /// The body a mode shows below the band, if any.
    public func body(for mode: NotchMode) -> NotchBody? {
        switch mode {
        case .hidden, .quiet: nil
        case .showing: content.showing
        case .expanded: content.expanded
        case .asking: content.prompt
        }
    }

    /// Height of a mode's content below the band.
    public func bodyHeight(for mode: NotchMode) -> CGFloat {
        switch mode {
        case .hidden, .quiet: 0
        case .showing: content.showing?.height(placement) ?? 0
        case .expanded: content.expanded?.height(placement) ?? metrics.expandedBodyHeight
        case .asking: (content.prompt?.height(placement) ?? 120) + metrics.askingPadding
        }
    }

    private func width(for mode: NotchMode) -> CGFloat {
        switch mode {
        case .hidden, .quiet: 0
        case .showing: content.showing?.width ?? metrics.showingWidth
        case .expanded: content.expanded?.width ?? metrics.expandedWidth
        case .asking: content.prompt?.width ?? metrics.askingWidth
        }
    }

    public func size(for mode: NotchMode) -> CGSize {
        let notch = geometry.notchSize
        let line = content.busy ? metrics.busyLine : metrics.quietLine
        if placement == .belowNotch {
            switch mode {
            case .hidden: return .zero
            // Wider and thicker while busy, so the moving band is easy to spot.
            case .quiet: return line
            case .showing, .expanded, .asking:
                return CGSize(width: width(for: mode), height: topBandHeight + row(for: mode) + bodyHeight(for: mode))
            }
        }
        if placement == .notch {
            let withEars = notch.width + 2 * metrics.ear
            switch mode {
            case .hidden: return notch
            case .quiet where indicatorUnderNotch:
                // The notch, a gap, then the line.
                return CGSize(width: max(notch.width, line.width), height: notch.height + NotchGeometry.sharedGap + line.height)
            case .quiet: return CGSize(width: withEars, height: notch.height)
            case .showing, .expanded, .asking:
                return CGSize(width: max(withEars, width(for: mode)),
                              height: notchTop(for: mode) + row(for: mode) + bodyHeight(for: mode))
            }
        }
        switch mode {
        case .hidden: return .zero
        case .quiet: return metrics.menuBarQuiet
        case .showing:
            let width = content.showing?.width ?? metrics.showingWidth + metrics.menuBarShowingExtra
            return CGSize(width: width, height: metrics.menuBarBand + bodyHeight(for: mode))
        case .expanded, .asking:
            return CGSize(width: width(for: mode), height: metrics.menuBarBand + row(for: mode) + bodyHeight(for: mode))
        }
    }

    /// The Switcher dots' row in a mode's size (only the open pill shows the dots).
    private func row(for mode: NotchMode) -> CGFloat { mode == .expanded ? switcherRowHeight : 0 }

    /// Fixed text width for a showing body, independent of the pill's open/close animation. In a docked part narrower
    /// than the app's own pill (a Split body, a Merged part) it's that part's text width.
    public var bodyTextWidth: CGFloat {
        if let width = dockedBodyWidth { return width - 2 * metrics.textSidePadding }
        return size(for: .showing).width - 2 * metrics.textSidePadding - (placement == .notch ? 2 * metrics.pillInset : 0)
    }

    /// The width a body gets in a docked part (`nil`: the pill's own, solo or a whole slot).
    public var dockedBodyWidth: CGFloat? {
        guard dockCanvas != nil, let frame = slot.frame else { return nil }
        switch slot.role {
        case .whole, .hidden: return nil
        case .top: return frame.width - 2 * metrics.pillInset
        case .middle, .bottom: return frame.width
        case .leftWing, .rightWing: return slot.bodyFrame?.width
        }
    }

    /// The activity level for the meter, 0...1; zero while off.
    public var level: Double { content.isActive ? min(1, max(0, content.level)) : 0 }

    // MARK: Menus

    /// Opens a menu from the pill. `NSMenu.popUp` returns only when the menu closes, so `isMenuOpen` is true
    /// exactly while it shows, and the pill stays expanded while the pointer is on the menu, outside the pill.
    /// A SwiftUI `Menu` can't say when it opens and closes, so the pill collapsed under it.
    public func popUpMenu(_ menu: NSMenu, from view: NSView?) {
        guard !isMenuOpen else { return }
        isMenuOpen = true
        presentMenu(menu, view)
        isMenuOpen = false
        onMenuClosed?()
    }

    // MARK: Hover

    /// Where the pill of a size hangs, in screen coordinates: top-centre at the notch, or at a docked whole slot.
    public func pillRect(size: CGSize) -> CGRect {
        if dockCanvas != nil, slot.role == .whole, let frame = slot.frame {
            return CGRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height)
        }
        return geometry.pillRect(size: size)
    }

    /// The pill's size as drawn: its own, or as wide as a docked whole slot (Merged capsules share one width). An
    /// open docked pill is as tall as its slot too: the slot may reach down over what was under the pointer.
    public func drawnSize(for mode: NotchMode) -> CGSize {
        let own = size(for: mode)
        guard dockCanvas != nil, slot.role == .whole, mode != .hidden, let frame = slot.frame else { return own }
        return CGSize(width: frame.width, height: mode == .expanded && slot.isOpen ? max(own.height, frame.height) : own.height)
    }

    /// The area the mouse must be in to keep (or start) the pill expanded, in screen coordinates.
    public func hoverRect() -> CGRect {
        if dockCanvas != nil, slot.role != .whole {
            // A docked part: what of it shows. A hidden slot is never a hover target.
            let visible = slot.isVisible ? (slot.visibleFrame ?? .zero) : .zero
            return isHovering && !visible.isEmpty ? visible.insetBy(dx: -10, dy: -10) : visible
        }
        let current = pillRect(size: drawnSize(for: mode))
        var base = mode == .hidden ? geometry.hotZone : current
        if placement == .belowNotch {
            // The notch still opens the panel, and the pointer can travel from it down to the panel.
            base = base.union(geometry.notchRect)
        }
        return isHovering ? base.insetBy(dx: -10, dy: -10) : base
    }

    /// Docked: what of this app's pill the pointer can be on, exactly (screen coordinates): a part's visible rect, a
    /// whole pill as drawn, or, hidden during a Split hover, its ear (`handoffFrame`). `nil`: nothing (hidden).
    public var dockHitRect: CGRect? {
        guard dockCanvas != nil else { return nil }
        guard slot.isVisible else { return slot.handoffFrame }
        if slot.role == .whole { return pillRect(size: drawnSize(for: mode)) }
        return slot.visibleFrame
    }

    /// Whether a click at this point lands on the pill as drawn (no hover margin). The panel takes clicks only there.
    public func clickContains(_ point: CGPoint) -> Bool {
        if dockCanvas != nil {
            guard slot.isVisible else { return false }
            if slot.role != .whole { return slot.visibleFrame?.contains(point) ?? false }
        }
        guard keepsMenuBarClear(mode) else {
            return mode == .hidden ? false : pillRect(size: drawnSize(for: mode)).contains(point)
        }
        let pill = pillRect(size: drawnSize(for: mode))
        let barBottom = geometry.screenFrame.maxY - menuBarDepth
        let body = CGRect(x: pill.minX, y: pill.minY, width: pill.width, height: max(0, barBottom - pill.minY))
        return body.contains(point) || geometry.notchRect.contains(point)
    }

    /// Whether the pointer is where it keeps (or starts) the pill expanded. With the menu bar kept
    /// clear, the menu bar beside the notch stays the menu bar's: only the notch and the part of the
    /// pill below the bar count.
    public func hoverContains(_ point: CGPoint) -> Bool {
        if dockCanvas != nil {
            if !slot.isVisible {
                // Hidden: only a Split ear while another app's pill is open (exact, no margin).
                return slot.handoffFrame?.contains(point) ?? false
            }
            if slot.role != .whole { return hoverRect().contains(point) }
        }
        guard keepsMenuBarClear(mode) else { return hoverRect().contains(point) }
        let pill = pillRect(size: drawnSize(for: mode))
        let barBottom = geometry.screenFrame.maxY - menuBarDepth
        var body = CGRect(x: pill.minX, y: pill.minY, width: pill.width, height: max(0, barBottom - pill.minY))
        var notch = geometry.notchRect
        if isHovering {
            body = CGRect(x: body.minX - 10, y: body.minY - 10, width: body.width + 20, height: body.height + 10)
            notch = notch.insetBy(dx: -10, dy: 0)
        }
        return body.contains(point) || notch.contains(point)
    }

    /// While yielding, the area that belongs to the neighbor's panel. Leaving it ends the yield.
    public func yieldZone() -> CGRect {
        let width = max(geometry.notchSize.width + 720, 820)
        return CGRect(x: geometry.centerX - width / 2, y: geometry.screenFrame.maxY - 520, width: width, height: 520)
    }
}
