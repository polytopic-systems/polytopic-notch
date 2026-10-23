import AppKit

/// Borderless panel that sits over the menu bar at the notch. It's transparent and ignores the mouse
/// except while the pointer is over the pill, so it never blocks menu bar items.
public final class NotchPanel: NSPanel {
    public init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = Self.level(placement: .notch, sharing: false, hovering: false)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    /// Level 27 (`.mainMenu + 3`), above the menu bar, while the notch is ours. While sharing with another
    /// notch app we sit lower, at the status-bar level (25): the neighbor's panels (mostly level 26–33,
    /// some 1000) open over our pill instead of under it. While the pointer is on our pill we rise above
    /// them to 100, below pop-up menus (101) so the pill's own menus still show, so clicks reach us even
    /// when a neighbor keeps a big click-catching transparent box over the area.
    public static func level(placement: NotchGeometry.Placement, sharing: Bool, hovering: Bool) -> NSWindow.Level {
        guard sharing, placement != .notch else { return .mainMenu + 3 }
        return hovering ? hoverLevel : .statusBar
    }

    public static let hoverLevel = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }

    // Allow sitting on top of the menu bar.
    public override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
