import Observation
import SwiftUI

/// How much an app wants the notch, for the dock to share it between docked apps. Ordered:
/// `none < quiet < notice < live < urgent`. A question waiting for an answer is urgent, a short post a notice,
/// a running session (listening, recording) live. Only read when the app has a dock.
public enum NotchWant: Int, Comparable, Codable, CaseIterable, Sendable {
    case none, quiet, notice, live, urgent

    public static func < (a: NotchWant, b: NotchWant) -> Bool { a.rawValue < b.rawValue }
}

/// A view the pill shows below the band, and the room it needs. The view observes the app's own model; it exists
/// only while its mode shows, so it must start and stop its own work on appear and disappear.
public struct NotchBody {
    /// Width of the pill while it shows this body; `nil`: the mode's usual width (`NotchMetrics`).
    public var width: CGFloat?
    /// Height below the band. A closure so it can follow the app's own settings (text size, lines) without the app
    /// setting the body again: it is read where the pill is sized, inside observation.
    public var height: @MainActor (NotchGeometry.Placement) -> CGFloat
    /// The attached outline's bottom corner radius while this body shows; `nil`: the mode's usual radius.
    public var bottomRadius: CGFloat?
    public var view: AnyView

    /// The same height wherever the pill hangs.
    public init(width: CGFloat? = nil, height: CGFloat, bottomRadius: CGFloat? = nil, view: AnyView) {
        self.init(width: width, bottomRadius: bottomRadius, height: { _ in height }, view: view)
    }

    public init(width: CGFloat? = nil, height: CGFloat, bottomRadius: CGFloat? = nil, @ViewBuilder content: () -> some View) {
        self.init(width: width, height: height, bottomRadius: bottomRadius, view: AnyView(content()))
    }

    /// A height that depends on where the pill hangs or on the app's own state.
    public init(width: CGFloat? = nil, bottomRadius: CGFloat? = nil,
                height: @escaping @MainActor (NotchGeometry.Placement) -> CGFloat, view: AnyView) {
        self.width = width
        self.height = height
        self.bottomRadius = bottomRadius
        self.view = view
    }

    public init(width: CGFloat? = nil, bottomRadius: CGFloat? = nil,
                height: @escaping @MainActor (NotchGeometry.Placement) -> CGFloat, @ViewBuilder content: () -> some View) {
        self.init(width: width, bottomRadius: bottomRadius, height: height, view: AnyView(content()))
    }
}

/// The status dot beside the notch, when the app wants its own rather than the theme's colour for the status.
public struct NotchDot: Equatable, Sendable {
    public var color: Color
    /// The dot breathes (a Core Animation pulse played by the window server, not the app).
    public var pulsing: Bool

    public init(color: Color, pulsing: Bool) {
        self.color = color
        self.pulsing = pulsing
    }
}

/// What the app shows at the notch. The one seam between an app and the pill: the app fills this (from its
/// own model) and the pill decides where and how big. It never reaches
/// back into the app.
///
/// Keep updates cheap: every change redraws whatever reads it. A meter level belongs here; per-word captions belong
/// in a body's own view, which observes the app's model directly.
@MainActor
@Observable
public final class NotchContent {
    public enum Status: String, Sendable {
        /// Nothing to show: no pill beyond the physical notch.
        case off
        /// Working, nothing new: a quiet indicator beside (or under) the notch.
        case quiet
        /// Something to show: the `showing` body drops below the notch.
        case showing
        /// Something needs the user: like `showing`, in the theme's attention colour.
        case attention
    }

    public var status: Status = .off
    /// How much this app wants the notch, for the dock. While `prompt` is set the dock is told `urgent` whatever this
    /// says. Without a dock nothing reads it.
    public var want: NotchWant = .none
    /// SF Symbol for the app or what it's doing.
    public var symbol = "circle.dotted"
    /// Shown in the band on screens without a notch, e.g. "Listening" or "Firewall".
    public var title = ""
    /// 0...1: activity for the small meter beside the notch and the quiet line.
    public var level: Double = 0
    /// Working on something the user waits for (a model loading): the meter becomes loading bars and the quiet
    /// line a moving band, a little bigger so it's easy to spot.
    public var busy = false
    /// The dot's colour and pulse; `nil`: the theme's colour for the status, pulsing while showing.
    public var dot: NotchDot?
    /// The quiet line's colour; `nil`: the theme's accent (attention colour while `.attention`).
    public var lineColor: Color?

    /// Below the band while showing (captions, a headline, an offer). `nil`: just the band.
    public var showing: NotchBody?
    /// What hovering opens. `nil`: an empty panel of the usual size.
    public var expanded: NotchBody?
    /// A question waiting for the user. Where the pill hangs from a notch it grows around this whether or not the
    /// pointer is there (`NotchMode.asking`); elsewhere `NotchPromptWindowController` shows it in a floating window.
    public var prompt: NotchBody?

    public init() {}

    public var isActive: Bool { status != .off }
}

/// Where this app's pill may go when several apps share the notch.
///
/// Without a dock every app is `solo`: today's behaviour, placed by the app's own geometry. With a dock
/// (`NotchPanelController(…, dock:)`), `NotchDockLayout.solve` hands each app a slot: its rect, its part of a shared
/// outline, a level offset, Switcher dots. Each app draws only its own slot.
public struct NotchSlot: Equatable, Sendable {
    /// The part of a shared outline this app draws.
    public enum Role: String, Equatable, Sendable, CaseIterable {
        /// The app's own pill (alone, or a separate capsule beside or below another app's).
        case whole
        /// Merged: attached to the notch, square bottom corners where the next app's part joins.
        case top
        /// Merged: between two parts, square everywhere.
        case middle
        /// Merged: the lowest part, rounded bottom corners, the stack's only shadow.
        case bottom
        /// Split: an ear of the band on that side of the notch, with its body below when it shows something.
        case leftWing, rightWing
        /// Another app has the notch: nothing drawn, click-through, not a hover target.
        case hidden
    }

    /// Edges of a slot that meet another app's slot: drawn square, with no stroke and no shadow.
    public struct Edges: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let left = Edges(rawValue: 1)
        public static let right = Edges(rawValue: 2)
        public static let top = Edges(rawValue: 4)
        public static let bottom = Edges(rawValue: 8)
    }

    public var role: Role = .whole
    /// Hovering may open the pill.
    public var mayExpand = true
    /// A question may take the pill; otherwise it goes to the floating window.
    public var mayAsk = true

    // Set by the dock. A solo slot leaves them at their defaults.

    /// Where the dock hangs on this screen: at the notch, below a stranger's notch or a menu bar manager's bar, or
    /// below the menu bar.
    public var placement: NotchGeometry.Placement = .notch
    /// The slot in screen coordinates (origin bottom-left). `nil`: solo, the pill places itself. For a Merged lower
    /// part it reaches up under the parts above (the "full tuck"); `visibleFrame` is what shows.
    public var frame: CGRect?
    /// Split: the body hanging below the band, including the shoulder at its top. The wing and its body are one
    /// shape in one window.
    public var bodyFrame: CGRect?
    /// What of the slot shows and takes hover, in screen coordinates.
    public var visibleFrame: CGRect?
    /// The y the dock hangs from (screen coordinates): the top of the screen, or just below a stranger or a bar.
    public var anchorY: CGFloat?
    public var joints: Edges = []
    public var bodyJoints: Edges = []
    /// Split: how deep the wing's straight neck reaches. A quiet wing's stops above the ear's rounded corner; a showing
    /// wing's reaches the menu bar's depth, where it shoulders out to its body.
    public var neckDepth: CGFloat = 0
    /// Added to the panel's window level: `-rank` in a Merged stack (0 for the top), 0 otherwise.
    public var levelOffset = 0
    /// Switcher: a dot for every docked app on this screen, in the user's order. Empty in the other styles.
    public var switcherDots: [NotchSwitcherDot] = []
    /// Merged: some part of the stack is hovered (or holds a menu), so the whole stack is at the hovered level,
    /// order kept. Raising only the hovered part would put a lower part over the captions above it.
    public var stackHovered = false
    /// Merged: only the lowest part casts a shadow, so joints never darken.
    public var castsShadow = true
    /// The dock lays this app out open (its expanded body): it is the hovered app, or a Switcher dot handed it the
    /// notch. Docked pills open only from this, so the app's own hover and the layout never disagree.
    public var isOpen = false
    /// Split, while another app's pill is open: this app's ear beside the notch (screen coordinates). The pointer
    /// on it hands the open pill to this app.
    public var handoffFrame: CGRect?

    public init(role: Role = .whole, mayExpand: Bool = true, mayAsk: Bool = true) {
        self.role = role
        self.mayExpand = mayExpand
        self.mayAsk = mayAsk
    }

    public init(role: Role, placement: NotchGeometry.Placement, frame: CGRect?, bodyFrame: CGRect? = nil,
                visibleFrame: CGRect? = nil, anchorY: CGFloat? = nil, joints: Edges = [], bodyJoints: Edges = [],
                neckDepth: CGFloat = 0, levelOffset: Int = 0, mayExpand: Bool, mayAsk: Bool,
                switcherDots: [NotchSwitcherDot] = [], stackHovered: Bool = false, castsShadow: Bool = true,
                isOpen: Bool = false, handoffFrame: CGRect? = nil) {
        self.role = role
        self.placement = placement
        self.frame = frame
        self.bodyFrame = bodyFrame
        self.visibleFrame = visibleFrame ?? frame
        self.anchorY = anchorY
        self.joints = joints
        self.bodyJoints = bodyJoints
        self.neckDepth = neckDepth
        self.levelOffset = levelOffset
        self.mayExpand = mayExpand
        self.mayAsk = mayAsk
        self.switcherDots = switcherDots
        self.stackHovered = stackHovered
        self.castsShadow = castsShadow
        self.isOpen = isOpen
        self.handoffFrame = handoffFrame
    }

    /// Alone at the notch: today's behaviour.
    public static let solo = NotchSlot()

    /// Another app has the notch: nothing drawn, click-through.
    public static func hidden(_ placement: NotchGeometry.Placement) -> NotchSlot {
        NotchSlot(role: .hidden, placement: placement, frame: nil, mayExpand: false, mayAsk: false, castsShadow: false)
    }

    public var isVisible: Bool { role != .hidden }
    /// Placed by a dock (not solo).
    public var isDocked: Bool { frame != nil || role == .hidden }
}
