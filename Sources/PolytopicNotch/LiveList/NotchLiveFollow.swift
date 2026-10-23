import Foundation

/// Which end of a live list the newest item is at.
public enum NotchLiveEdge: Sendable, Equatable {
    /// Newest first: new items arrive at the top (an event log).
    case top
    /// Newest last: new items arrive at the bottom (a transcript, a chat).
    case bottom

    /// Whether a scroll view showing `visible` (in content coordinates) of content `contentHeight` tall is at this
    /// edge, within `tolerance` points. Content shorter than its view is at both edges.
    public func contains(visible: CGRect, contentHeight: CGFloat, tolerance: CGFloat = 4) -> Bool {
        switch self {
        case .top: visible.minY <= tolerance
        case .bottom: visible.maxY >= contentHeight - tolerance
        }
    }
}

/// When a live list follows the newest item and when it holds still: the algorithm behind `NotchLiveFeed`, as a
/// pure value with the clock passed in (no timers inside; the feed schedules one check at `nextDeadline`).
///
/// - **Live**: the list shows the latest items and keeps its live edge in view.
/// - **Held**: the list shows what it showed and doesn't move. Reasons (`Reason`): the pointer is on an element
///   marked as an action, the pill's menu is open, the user scrolled away from the live edge to read, or the app
///   holds it for its own reason.
///
/// Back to live:
/// - pointer, menu and app reasons gone and the list at its live edge: after `Timing.actionGrace`, so moving from
///   one row's buttons to the next row's never lets the list jump in between;
/// - scrolled away: held while the user reads; after `Timing.readingIdle` with no scrolling and no other reason it
///   returns, and asks the view to scroll back to the live edge (`takeScrollBack()`), so a forgotten scroll comes
///   back by itself;
/// - scrolled back to the live edge by hand: at once (when no other reason holds it);
/// - `resume()` (the "N new" capsule): at once, whatever holds it.
///
/// A new reason before a deadline cancels it; the deadline starts again, in full, when the last reason goes.
public struct NotchLiveFollow: Sendable, Equatable {
    public typealias Instant = ContinuousClock.Instant

    public enum Reason: Hashable, Sendable {
        /// The pointer is on an element marked as an action (`notchLiveAction`).
        case pointer
        /// A menu from the pill is open (`NotchViewModel.isMenuOpen`).
        case menu
        /// The list is scrolled away from its live edge.
        case reading
        /// The app holds the list (e.g. while a row shows the result of a click).
        case app(String)
    }

    public enum State: Equatable, Sendable {
        case live
        /// Held. An empty set means no reason is left and the list returns at `nextDeadline`.
        case held(Set<Reason>)
    }

    public struct Timing: Equatable, Sendable {
        /// Pointer off the actions (and menu and app holds gone) at the live edge: this long before following again.
        public var actionGrace: Duration
        /// Scrolled away and nothing else holds: this long without scrolling before returning to the live edge.
        public var readingIdle: Duration

        public init(actionGrace: Duration = .milliseconds(1200), readingIdle: Duration = .seconds(5)) {
            self.actionGrace = actionGrace
            self.readingIdle = readingIdle
        }

        public static let standard = Timing()
    }

    public var timing: Timing
    /// What holds the list now (`.reading` while scrolled away).
    public private(set) var reasons: Set<Reason> = []
    public private(set) var isHeld = false
    /// What the view last said: whether the list is at its live edge.
    public private(set) var atLiveEdge = true
    /// When the list returns to live unless something changes first. `nil`: no return is pending.
    public private(set) var nextDeadline: Instant?
    private var scrollBack = false

    public init(timing: Timing = .standard) {
        self.timing = timing
    }

    public var state: State { isHeld ? .held(reasons) : .live }

    /// Reasons other than reading: while any is there, nothing returns.
    private var blocking: Set<Reason> { reasons.subtracting([.reading]) }

    /// A reason starts holding the list (`.reading` comes from `scrolled`, not from here).
    public mutating func hold(_ reason: Reason, now: Instant) {
        guard reason != .reading else { return }
        reasons.insert(reason)
        isHeld = true
        nextDeadline = nil
    }

    /// A reason stops holding. When it was the last one, the return deadline starts: `actionGrace` at the live edge,
    /// `readingIdle` while scrolled away.
    public mutating func release(_ reason: Reason, now: Instant) {
        guard reason != .reading, reasons.remove(reason) != nil, isHeld, blocking.isEmpty else { return }
        nextDeadline = now + (atLiveEdge ? timing.actionGrace : timing.readingIdle)
    }

    /// The user scrolled (`moved`), or the view found the list at or away from its live edge.
    public mutating func scrolled(atLiveEdge: Bool, moved: Bool = true, now: Instant) {
        let wasAtEdge = self.atLiveEdge
        self.atLiveEdge = atLiveEdge
        if !atLiveEdge {
            guard moved || wasAtEdge else { return }
            reasons.insert(.reading)
            isHeld = true
            // Every movement while reading starts the idle wait again.
            nextDeadline = blocking.isEmpty ? now + timing.readingIdle : nil
        } else if !wasAtEdge {
            reasons.remove(.reading)
            if blocking.isEmpty {
                // Back at the edge by hand: live at once.
                isHeld = false
                nextDeadline = nil
            }
        }
    }

    /// Applies a deadline that has passed. Returns whether the list went live.
    @discardableResult
    public mutating func advance(now: Instant) -> Bool {
        guard isHeld, let deadline = nextDeadline, now >= deadline, blocking.isEmpty else { return false }
        if !atLiveEdge || reasons.contains(.reading) { scrollBack = true }
        goLive()
        return true
    }

    /// Live now, whatever holds it (the user asked: the "N new" capsule). Asks the view to scroll to the live edge.
    public mutating func resume() {
        scrollBack = true
        goLive()
    }

    /// Live at the edge with nothing held (the pill closed; the next open starts live).
    public mutating func reset() {
        self = NotchLiveFollow(timing: timing)
    }

    /// Whether the view should scroll back to the live edge (once: reading it clears it).
    public mutating func takeScrollBack() -> Bool {
        defer { scrollBack = false }
        return scrollBack
    }

    private mutating func goLive() {
        reasons = []
        isHeld = false
        atLiveEdge = true
        nextDeadline = nil
    }
}
