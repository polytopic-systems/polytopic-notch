import AppKit

/// Which screen the notch pill lives on.
public enum NotchDisplay: String, Codable, CaseIterable, Sendable {
    /// The built-in notched display (or the main screen if there is none).
    case builtIn
    /// Whichever screen the frontmost app is on.
    case active
}

/// Where the notch is on a screen, and where the pill hangs from.
/// On screens without a notch the pill hangs just below the menu bar, Bartender-style.
public struct NotchGeometry: Equatable, Sendable {
    public enum Placement: Equatable, Hashable, Sendable {
        /// Grows out of the physical notch.
        case notch
        /// No notch on this screen: a bar hanging just below the menu bar.
        case menuBar
        /// Another app (Bartender's Top Shelf, Boring Notch, an island…) is using the notch, or a menu bar
        /// manager's bar is in the way, so everything hangs just below it.
        case belowNotch
    }

    public var screenFrame: CGRect
    public var placement: Placement
    public var hasNotch: Bool
    /// The physical notch. Zero width on screens without one.
    public var notchSize: CGSize
    /// Horizontal centre of the notch (or the screen) in screen coordinates.
    public var centerX: CGFloat
    public var menuBarHeight: CGFloat
    /// Extra distance the pill is pushed down to clear another app's bar under the menu bar.
    public var drop: CGFloat = 0

    /// Gap between the menu bar and the floating bar on screens without a notch.
    public static let barGap: CGFloat = 6
    /// Gap between the notch and our pill when the notch is shared.
    public static let sharedGap: CGFloat = 5

    public init(screenFrame: CGRect, safeAreaTop: CGFloat, auxiliaryTopLeft: CGRect?, auxiliaryTopRight: CGRect?,
                menuBarHeight: CGFloat) {
        self.screenFrame = screenFrame
        self.menuBarHeight = menuBarHeight
        if safeAreaTop > 0, let left = auxiliaryTopLeft, let right = auxiliaryTopRight {
            let width = max(0, screenFrame.width - left.width - right.width)
            hasNotch = width > 0
            placement = width > 0 ? .notch : .menuBar
            notchSize = CGSize(width: width, height: safeAreaTop)
            centerX = screenFrame.minX + left.width + width / 2
        } else {
            hasNotch = false
            placement = .menuBar
            notchSize = CGSize(width: 0, height: menuBarHeight)
            centerX = screenFrame.midX
        }
    }

    @MainActor
    public init(screen: NSScreen) {
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        self.init(screenFrame: screen.frame,
                  safeAreaTop: screen.safeAreaInsets.top,
                  auxiliaryTopLeft: screen.auxiliaryTopLeftArea,
                  auxiliaryTopRight: screen.auxiliaryTopRightArea,
                  menuBarHeight: menuBar > 0 ? menuBar : NSStatusBar.system.thickness)
    }

    /// A stand-in screen for when there is none (tests, a headless start).
    public static let fallback = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), safeAreaTop: 0,
                                               auxiliaryTopLeft: nil, auxiliaryTopRight: nil, menuBarHeight: 24)

    /// The same screen, leaving the notch to a neighbor (or taking it back).
    public func sharingNotch(_ shares: Bool) -> NotchGeometry {
        var copy = self
        copy.placement = hasNotch ? (shares ? .belowNotch : .notch) : .menuBar
        copy.drop = 0
        return copy
    }

    /// Moves the pill under a bar that's showing just below the menu bar (the Bartender Bar, the Ice Bar…), when
    /// that bar is in the pill's way. `reach` is the widest the pill gets.
    public func avoiding(_ obstruction: CGRect?, reach: CGFloat) -> NotchGeometry {
        guard let obstruction, obstruction.intersects(screenFrame),
              obstruction.maxX > centerX - reach / 2, obstruction.minX < centerX + reach / 2 else { return self }
        var copy = self
        // A pill attached to the notch can't slide down, so it detaches while the bar is up.
        if copy.placement == .notch { copy.placement = .belowNotch }
        copy.drop = max(0, copy.anchorY - (obstruction.minY - Self.sharedGap))
        return copy
    }

    /// The physical notch in screen coordinates; empty on screens without one.
    public var notchRect: CGRect {
        guard hasNotch else { return .zero }
        return CGRect(x: centerX - notchSize.width / 2, y: screenFrame.maxY - notchSize.height,
                      width: notchSize.width, height: notchSize.height)
    }

    /// The y coordinate (screen space, origin bottom-left) the pill's top edge sits on.
    public var anchorY: CGFloat {
        switch placement {
        case .notch: screenFrame.maxY
        case .menuBar: screenFrame.maxY - menuBarHeight - Self.barGap - drop
        case .belowNotch: screenFrame.maxY - notchSize.height - Self.sharedGap - drop
        }
    }

    /// The pill's rectangle in screen coordinates for a given size.
    public func pillRect(size: CGSize) -> CGRect {
        CGRect(x: centerX - size.width / 2, y: anchorY - size.height, width: size.width, height: size.height)
    }

    /// Where hovering wakes the pill when nothing is showing: the notch itself, or the middle of the menu bar.
    public var hotZone: CGRect {
        if hasNotch {
            return notchRect
        }
        let width: CGFloat = 220
        return CGRect(x: centerX - width / 2, y: screenFrame.maxY - menuBarHeight, width: width, height: menuBarHeight)
    }

    /// A fixed transparent panel big enough for the largest pill, so SwiftUI can animate inside it.
    public func panelFrame(maxSize: CGSize) -> CGRect {
        CGRect(x: centerX - maxSize.width / 2, y: anchorY - maxSize.height, width: maxSize.width, height: maxSize.height)
    }

    @MainActor
    public static func screen(for choice: NotchDisplay) -> NSScreen? {
        switch choice {
        case .builtIn: preferredScreen()
        case .active: NSScreen.main ?? preferredScreen()
        }
    }

    /// Prefer the built-in notched display; otherwise the main screen.
    @MainActor
    public static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }
}
