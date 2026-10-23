import Foundation
import Observation

/// A live list's items, and whether the list follows them: the app publishes the latest items, the list
/// (`NotchLiveList`) shows `shown`, which changes only while the list is live (`NotchLiveFollow` decides).
///
///     let feed = NotchLiveFeed<Event>(edge: .top)        // newest first
///     feed.publish(events)                               // whenever the app's list changes
///
/// While held, `shown` stays exactly as it was and `pendingNew` counts what arrived on the live side since; the list
/// shows that as an "N new" capsule. Return deadlines run as one scheduled task, and only while a list view shows
/// the feed (`attach`/`detach`, called by `NotchLiveList`): nothing runs while the pill is closed, and closing it
/// makes the feed live again.
@MainActor
@Observable
public final class NotchLiveFeed<Item: Identifiable & Equatable> {
    public typealias Instant = ContinuousClock.Instant

    public let edge: NotchLiveEdge
    /// What the list shows.
    public private(set) var shown: [Item] = []
    /// What the app published last.
    public private(set) var latest: [Item] = []
    /// While held: items on the live side of `shown` that it doesn't show yet. 0 while live.
    public private(set) var pendingNew = 0
    public private(set) var follow: NotchLiveFollow
    /// Changes each time the list should scroll to its live edge (the view observes it).
    public private(set) var scrollToEdgeRequest = 0

    @ObservationIgnored private let now: @MainActor () -> Instant
    @ObservationIgnored private var check: Task<Void, Never>?
    @ObservationIgnored private var attachments = 0
    @ObservationIgnored private var pointerTokens: Set<AnyHashable> = []

    /// `now` is for tests; the deadlines are slept on the continuous clock.
    public init(edge: NotchLiveEdge, timing: NotchLiveFollow.Timing = .standard,
                now: @escaping @MainActor () -> Instant = { ContinuousClock.now }) {
        self.edge = edge
        self.follow = NotchLiveFollow(timing: timing)
        self.now = now
    }

    public var isHeld: Bool { follow.isHeld }
    public var state: NotchLiveFollow.State { follow.state }

    public var timing: NotchLiveFollow.Timing {
        get { follow.timing }
        set { follow.timing = newValue }
    }

    /// Whether a list view shows the feed now.
    public var isAttached: Bool { attachments > 0 }

    /// The app's latest items, in display order (newest first for `.top`, newest last for `.bottom`).
    public func publish(_ latest: [Item]) {
        self.latest = latest
        apply()
    }

    /// Live now, showing the latest items, and scroll to the live edge (the capsule's click).
    public func resumeLive() {
        follow.resume()
        pointerTokens = []
        apply()
    }

    /// Holds the list for the app's own reason (use `.app("…")`); `release` with the same reason lets it go.
    public func hold(_ reason: NotchLiveFollow.Reason) {
        follow.hold(reason, now: now())
        apply()
    }

    public func release(_ reason: NotchLiveFollow.Reason) {
        follow.release(reason, now: now())
        apply()
    }

    /// Live, showing the latest items, nothing held (e.g. the app switched what the list shows).
    public func reset() {
        follow.reset()
        pointerTokens = []
        apply()
    }

    /// A list view appeared (from its `onAppear`).
    public func attach() {
        attachments += 1
        schedule()
    }

    /// A list view went away (its `onDisappear`). The last one makes the feed live and stops its check.
    public func detach() {
        attachments = max(0, attachments - 1)
        guard attachments == 0 else { return }
        reset()
    }

    // MARK: From the list view

    /// The pointer entered or left an element marked as an action (`token` tells the elements apart, so leaving
    /// one row after entering the next doesn't drop the hold).
    func actionHover(_ inside: Bool, token: AnyHashable) {
        if inside {
            let first = pointerTokens.isEmpty
            pointerTokens.insert(token)
            if first || !follow.reasons.contains(.pointer) { hold(.pointer) }
        } else if pointerTokens.remove(token) != nil, pointerTokens.isEmpty {
            release(.pointer)
        }
    }

    /// The pill's menu opened or closed.
    func menu(open: Bool) {
        guard open != follow.reasons.contains(.menu) else { return }
        open ? hold(.menu) : release(.menu)
    }

    /// The view's scroll position: at the live edge or not, and whether the user moved it.
    func scrolled(atLiveEdge: Bool, moved: Bool) {
        follow.scrolled(atLiveEdge: atLiveEdge, moved: moved, now: now())
        apply()
    }

    /// Applies a passed deadline (the scheduled check calls it).
    func checkDeadline() {
        follow.advance(now: now())
        apply()
    }

    /// Whether a deadline check is scheduled (tests: nothing may stay scheduled after `detach`).
    var hasScheduledCheck: Bool { check != nil }

    // MARK: Applying

    private func apply() {
        if follow.isHeld {
            let count = Self.pendingCount(shown: shown, latest: latest, edge: edge)
            if pendingNew != count { pendingNew = count }
        } else {
            if shown != latest { shown = latest }
            if pendingNew != 0 { pendingNew = 0 }
        }
        if follow.takeScrollBack() { scrollToEdgeRequest &+= 1 }
        schedule()
    }

    /// One check at the follow's next deadline, only while a view shows the feed.
    private func schedule() {
        check?.cancel()
        check = nil
        guard isAttached, let deadline = follow.nextDeadline else { return }
        check = Task { [weak self] in
            try? await Task.sleep(until: deadline, tolerance: .milliseconds(20), clock: .continuous)
            guard !Task.isCancelled, let self else { return }
            self.check = nil
            self.checkDeadline()
        }
    }

    /// Items of `latest` on the live side of what `shown` shows: beyond the live-most shown item that is still
    /// there (items dropped from the far side don't count), and not shown.
    static func pendingCount(shown: [Item], latest: [Item], edge: NotchLiveEdge) -> Int {
        let shownIDs = Set(shown.map(\.id))
        let liveSideFirst = edge == .top ? shown : shown.reversed()
        let ordered = edge == .top ? latest : latest.reversed()
        let latestIndex = Dictionary(ordered.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let anchor = liveSideFirst.lazy.compactMap { latestIndex[$0.id] }.first ?? ordered.count
        return ordered[..<anchor].reduce(0) { $0 + (shownIDs.contains($1.id) ? 0 : 1) }
    }
}
