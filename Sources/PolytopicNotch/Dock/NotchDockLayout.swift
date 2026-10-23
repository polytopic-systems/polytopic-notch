import CoreGraphics
import Foundation

/// The dock's layout: one pure function every docked app runs on the same announcements. There is no leader; each
/// app positions and draws only its own window from its own slot, and clicks and hover stay with the owning app.
///
/// - Expanding (hover) and urgent questions are exclusive in every style (except that hovering a Merged stack keeps
///   the stack and widens it); the styles differ in the passive state.
/// - A stranger notch app or a menu bar manager's bar reported by any app moves everyone below it.
/// - Fewer than two apps showing anything: today's solo pill.
public enum NotchDockLayout {
    public static func solve(style requested: NotchSharingStyle, screen: NotchDockScreen,
                             participants all: [NotchDockAnnouncement], order: [String], urgentHold: NotchUrgentHold,
                             now: Date, metrics m: NotchDockMetrics = .standard) -> [Int32: NotchSlot] {
        // Only apps on this display take part; a pid appears once (last wins).
        var byPID: [Int32: NotchDockAnnouncement] = [:]
        for a in all where a.displayID == screen.displayID { byPID[a.pid] = a }
        guard !byPID.isEmpty else { return [:] }

        let ordered = byPID.values.sorted { userRank($0, order) < userRank($1, order) }
        // A style some participant can't draw falls back to Priority for everyone.
        let style = ordered.allSatisfy { $0.supports(requested) } ? requested : .priority

        var frame = Frame(screen: screen, metrics: m)
        frame.avoid(strangers: ordered.contains { $0.seesStranger },
                    bars: ordered.compactMap(\.barRect), reach: reach(ordered, frame: frame, style: style))

        var result: [Int32: NotchSlot] = [:]
        for a in ordered { result[a.pid] = hidden(frame) }

        // Merged, by design: hovering any part keeps the stack, widens all of it to the expanded width and lets
        // only the hovered app's part grow taller. Urgent questions wait in their floating windows meanwhile.
        let members = ordered.filter { $0.want > .none || $0.isSticky }
        if style == .merged, members.count >= 2, let focus = focus(members.filter(\.isSticky), order: order) {
            for (pid, slot) in merged(members, frame: frame, focus: focus) { result[pid] = slot }
            return snapped(result, scale: screen.scale)
        }

        // Otherwise active states are exclusive: a hovered or menu-holding app (sticky) or a Switcher dot's target,
        // else an urgent question within its hold, gets the whole notch; everyone else steps aside.
        if let active = activeOwner(ordered, style: style, hold: urgentHold, now: now, order: order) {
            result[active.owner.pid] = whole(active.owner, frame: frame, style: style, ordered: ordered,
                                             mayAsk: active.owner.want == .urgent, open: active.open,
                                             coverWidth: active.coverWidth)
            // Split, during a hover: each other app's ear still hands the open pill over (no notch: exclusive).
            if style == .split, active.open, members.count >= 2, frame.placement == .notch,
               let notch = frame.screen.notchRect {
                let passive = split(members, frame: frame)
                for a in members where a.pid != active.owner.pid {
                    guard let wing = passive[a.pid]?.frame else { continue }
                    let left = passive[a.pid]?.role == .leftWing
                    let minX = left ? wing.minX : max(wing.minX, notch.maxX)
                    let maxX = left ? min(wing.maxX, notch.minX) : wing.maxX
                    guard maxX > minX else { continue }
                    result[a.pid]?.handoffFrame = CGRect(x: minX, y: frame.anchorY - notch.height,
                                                         width: maxX - minX, height: notch.height)
                }
            }
            return snapped(result, scale: screen.scale)
        }

        if style == .priority || style == .switcher || members.count < 2 {
            let owner = ordered.min { passiveRank($0, hold: urgentHold, now: now, order: order) <
                passiveRank($1, hold: urgentHold, now: now, order: order) }!
            result[owner.pid] = whole(owner, frame: frame, style: style, ordered: ordered, mayAsk: owner.want == .urgent)
            return snapped(result, scale: screen.scale)
        }

        let slots = style == .split ? split(members, frame: frame) : merged(members, frame: frame, focus: nil)
        for (pid, slot) in slots { result[pid] = slot }
        return snapped(result, scale: screen.scale)
    }

    // MARK: Ranking

    struct UserRank: Comparable {
        var index: Int, appID: String, pid: Int32
        static func < (a: Self, b: Self) -> Bool { (a.index, a.appID, a.pid) < (b.index, b.appID, b.pid) }
    }

    static func userRank(_ a: NotchDockAnnouncement, _ order: [String]) -> UserRank {
        UserRank(index: order.firstIndex(of: a.appID) ?? Int.max, appID: a.appID, pid: a.pid)
    }

    /// An urgent want past its hold competes as `notice` (above quiet, below a live session).
    static func effectiveWant(_ a: NotchDockAnnouncement, hold: NotchUrgentHold, now: Date) -> NotchWant {
        a.want == .urgent && !hold.holds(since: a.since, now: now) ? .notice : a.want
    }

    struct PassiveRank: Comparable {
        var want: Int, since: Date, user: UserRank
        static func < (a: Self, b: Self) -> Bool {
            if a.want != b.want { return a.want > b.want }
            if a.since != b.since { return a.since < b.since }
            return a.user < b.user
        }
    }

    static func passiveRank(_ a: NotchDockAnnouncement, hold: NotchUrgentHold, now: Date, order: [String]) -> PassiveRank {
        PassiveRank(want: effectiveWant(a, hold: hold, now: now).rawValue, since: a.since, user: userRank(a, order))
    }

    /// Of several sticky apps (a hover handing over from one part to another), the one that is open: a menu holder
    /// first (its menu hangs from its pill), then the one hovered first (the incumbent), then the user's order. The
    /// incumbent lets go as soon as it sees the pointer on a hovered peer (`NotchPanelController`), so this lasts one
    /// message, and since every app agrees the incumbent is open until then, two pills are never open at once.
    static func focus(_ sticky: [NotchDockAnnouncement], order: [String]) -> NotchDockAnnouncement? {
        sticky.min { a, b in
            if a.menuOpen != b.menuOpen { return a.menuOpen }
            let sa = a.hoverSince ?? .distantPast, sb = b.hoverSince ?? .distantPast
            if sa != sb { return sa < sb }
            return userRank(a, order) < userRank(b, order)
        }
    }

    struct Active {
        var owner: NotchDockAnnouncement
        /// Laid out open (expanded): hovered, holding a menu, or handed the notch by a Switcher dot.
        var open: Bool
        /// Switcher: the open pill is at least as wide as the claimer's was, so the dot just clicked stays inside it.
        var coverWidth: CGFloat = 0
    }

    static func activeOwner(_ ordered: [NotchDockAnnouncement], style: NotchSharingStyle, hold: NotchUrgentHold,
                            now: Date, order: [String]) -> Active? {
        // Switcher: the latest dot click decides until its claimer clears it (the pointer left the dock). Not only
        // while someone is hovered: right after the click nobody may be (the claimer's pill is gone and the target's
        // hover hasn't begun), and dropping the claim then flashed the claimer back under the pointer, which hovered
        // it again and re-applied the claim, round and round.
        if style == .switcher,
           let claimer = ordered.filter({ c in c.switcherClaim.map { claim in ordered.contains { $0.pid == claim.pid } } ?? false })
               .max(by: { $0.switcherClaim!.at < $1.switcherClaim!.at }),
           let claim = claimer.switcherClaim, let target = ordered.first(where: { $0.pid == claim.pid }) {
            let width = claimer.pid == target.pid ? 0 : CGFloat(claimer.sizes.expanded?.width ?? 0)
            return Active(owner: target, open: true, coverWidth: width)
        }
        if let first = focus(ordered.filter(\.isSticky), order: order) {
            return Active(owner: first, open: true)
        }
        // Two urgent questions: the earlier one asks in the notch, the other uses its floating window.
        return ordered.filter { $0.want == .urgent && hold.holds(since: $0.since, now: now) }
            .min { ($0.since, userRank($0, order)) < ($1.since, userRank($1, order)) }
            .map { Active(owner: $0, open: false) }
    }

    // MARK: Frame (placement and anchor)

    struct Frame {
        var screen: NotchDockScreen
        var metrics: NotchDockMetrics
        var placement: NotchGeometry.Placement
        /// y of the top edge of whatever hangs from the top (screen coordinates).
        var anchorY: CGFloat

        init(screen s: NotchDockScreen, metrics: NotchDockMetrics) {
            screen = s
            self.metrics = metrics
            if s.notchRect != nil {
                placement = .notch
                anchorY = s.screenFrame.maxY
            } else {
                placement = .menuBar
                anchorY = s.screenFrame.maxY - s.menuBarHeight - metrics.barGap
            }
        }

        var centerX: CGFloat { screen.centerX }
        var usableWidth: CGFloat { screen.screenFrame.width - 2 * metrics.screenMargin }
        var notchHeight: CGFloat { screen.notchRect?.height ?? 0 }
        var band: CGFloat { metrics.band(placement, notchHeight: notchHeight) }

        /// A stranger notch app or a bar under the menu bar reported by *any* participant moves everyone below it.
        mutating func avoid(strangers: Bool, bars: [CGRect], reach: CGFloat) {
            if strangers, let notch = screen.notchRect {
                placement = .belowNotch
                anchorY = notch.minY - metrics.sharedGap
            }
            let relevant = bars.filter { $0.intersects(screen.screenFrame) && !$0.isEmpty }
            guard let first = relevant.first else { return }
            let union = relevant.dropFirst().reduce(first) { $0.union($1) }
            guard union.maxX > centerX - reach / 2, union.minX < centerX + reach / 2 else { return }
            if placement == .notch { placement = .belowNotch }
            anchorY = min(anchorY, union.minY - metrics.sharedGap)
        }
    }

    /// The widest the dock gets horizontally; a bar outside this span doesn't push anyone down.
    static func reach(_ ordered: [NotchDockAnnouncement], frame: Frame, style: NotchSharingStyle) -> CGFloat {
        let m = frame.metrics
        let notchWidth = frame.screen.notchRect?.width ?? 0
        let widest = ordered.map { size($0, frame: frame).width }.max() ?? 0
        let band = notchWidth + 2 * m.ear * CGFloat(max(1, (ordered.count + 1) / 2))
        switch style {
        case .split:
            let capsules = ordered.map { size($0, frame: frame).width }.reduce(0, +)
                + CGFloat(max(0, ordered.count - 1)) * m.capsuleGap
            return max(band, capsules, widest * CGFloat(max(1, ordered.count)))
        default:
            return max(band, widest)
        }
    }

    /// Announced size for the app's current mode (or `mode`), with defaults.
    static func size(_ a: NotchDockAnnouncement, frame: Frame, mode: NotchMode? = nil) -> (width: CGFloat, bodyHeight: CGFloat) {
        let m = frame.metrics
        let fallbackWidth = frame.placement == .notch ? (frame.screen.notchRect?.width ?? 0) + 2 * m.ear : m.capsuleWidth
        guard let s = a.sizes[mode ?? a.rest] else { return (fallbackWidth, 0) }
        return (CGFloat(s.width), max(0, CGFloat(s.bodyHeight)))
    }

    static func hidden(_ frame: Frame) -> NotchSlot {
        var slot = NotchSlot.hidden(frame.placement)
        slot.anchorY = frame.anchorY
        return slot
    }

    // MARK: Solo / exclusive

    static func whole(_ a: NotchDockAnnouncement, frame: Frame, style: NotchSharingStyle,
                      ordered: [NotchDockAnnouncement], mayAsk: Bool, open: Bool = false,
                      coverWidth: CGFloat = 0) -> NotchSlot {
        // An app granted its question is sized for it at once, before it has announced the asking mode; an open one
        // by its expanded size, before it has announced that.
        let mode: NotchMode? = mayAsk && a.sizes.asking != nil ? .asking : open ? .expanded : nil
        let s = size(a, frame: frame, mode: mode)
        var dots: [NotchSwitcherDot] = []
        if style == .switcher, ordered.count > 1 {
            dots = ordered.map { NotchSwitcherDot(pid: $0.pid, appID: $0.appID, symbol: $0.symbol, isCurrent: $0.pid == a.pid) }
        }
        // Switcher: the open pill shows the dots in a row of their own above its body (`NotchViewModel.switcherRowHeight`),
        // in every placement. Apps don't announce the row; it's added here.
        let row = mode == .expanded && !dots.isEmpty ? frame.metrics.switcherRow : 0
        var width: CGFloat
        var height: CGFloat
        if frame.placement == .notch, let notch = frame.screen.notchRect {
            width = max(s.width, notch.width)
            height = notch.height + row + s.bodyHeight
        } else {
            width = s.width
            height = frame.band + row + s.bodyHeight
        }
        // An open pill covers what was under the pointer when its hover began (and a Switcher target the claimer's
        // width), so opening never leaves a still pointer outside it.
        width = max(width, coverWidth)
        if open, a.isSticky, let hold = a.hoverHold, !hold.isEmpty {
            width = max(width, 2 * max(frame.centerX - hold.minX, hold.maxX - frame.centerX))
            height = max(height, frame.anchorY - hold.minY)
        }
        width = min(width, frame.usableWidth)
        let rect = CGRect(x: frame.centerX - width / 2, y: frame.anchorY - height, width: width, height: height)
        return NotchSlot(role: .whole, placement: frame.placement, frame: rect, anchorY: frame.anchorY,
                         mayExpand: true, mayAsk: mayAsk, switcherDots: dots, isOpen: open)
    }

    // MARK: Split

    /// N apps share the band around the notch in the user's order: the first ⌈N/2⌉ on the left (first = outermost),
    /// the rest on the right. Each app keeps one ear (40 pt: 34 straight + the 6 pt flare) of visible band. The two
    /// innermost wings reach under the notch to `splitSlit / 2` from its centre, so their join is hidden inside the
    /// notch. With two apps the band is exactly today's quiet ears; each extra app adds one ear.
    ///
    /// Bodies (apps showing something) hang below the band across one shared width (the widest announced showing
    /// width): one showing app spreads over all of it; several split it into equal parts with a 6 pt slit between
    /// them, in the user's order. Each app keeps its own ear either way.
    /// Without a notch (or below a stranger): separate capsules side by side, each at its own size.
    static func split(_ members: [NotchDockAnnouncement], frame: Frame) -> [Int32: NotchSlot] {
        let m = frame.metrics
        var slots: [Int32: NotchSlot] = [:]
        guard frame.placement == .notch, let notch = frame.screen.notchRect else {
            let sizes = members.map { size($0, frame: frame) }
            let gaps = CGFloat(members.count - 1) * m.capsuleGap
            let natural = sizes.map(\.width).reduce(0, +)
            let shrink = min(1, max(0, frame.usableWidth - gaps) / max(1, natural))
            var x = frame.centerX - (natural * shrink + gaps) / 2
            for (a, s) in zip(members, sizes) {
                let w = s.width * shrink, h = frame.band + s.bodyHeight
                slots[a.pid] = NotchSlot(role: .whole, placement: frame.placement,
                                         frame: CGRect(x: x, y: frame.anchorY - h, width: w, height: h),
                                         anchorY: frame.anchorY, mayExpand: true, mayAsk: false)
                x += w + m.capsuleGap
            }
            return slots
        }

        let cx = frame.centerX, top = frame.anchorY
        let menuBarDepth = max(notch.height, frame.screen.menuBarHeight)
        let quietNeck = max(0, min(menuBarDepth, notch.height - m.earCornerRadius))
        let showers = members.filter { $0.rest == .showing && size($0, frame: frame).bodyHeight > 0 }
        let showerIDs = Set(showers.map(\.pid))

        func wing(_ a: NotchDockAnnouncement, role: NotchSlot.Role, minX: CGFloat, maxX: CGFloat,
                  joints: NotchSlot.Edges) -> NotchSlot {
            let shows = showerIDs.contains(a.pid)
            let depth = shows ? menuBarDepth : notch.height
            return NotchSlot(role: role, placement: .notch,
                             frame: CGRect(x: minX, y: top - depth, width: maxX - minX, height: depth),
                             anchorY: top, joints: joints, neckDepth: shows ? menuBarDepth : quietNeck,
                             mayExpand: true, mayAsk: false)
        }

        let leftCount = (members.count + 1) / 2
        let left = Array(members.prefix(leftCount)), right = Array(members.dropFirst(leftCount))
        let inner = m.splitSlit / 2
        for (j, a) in left.reversed().enumerated() {   // from the notch outwards
            let minX = notch.minX - m.ear * CGFloat(j + 1)
            let maxX = j == 0 ? cx - inner : notch.minX - m.ear * CGFloat(j)
            var joints: NotchSlot.Edges = []   // the inner wings meet across a slit hidden in the notch, not a joint
            if j < left.count - 1 { joints.insert(.left) }
            if j > 0 { joints.insert(.right) }
            slots[a.pid] = wing(a, role: .leftWing, minX: minX, maxX: maxX, joints: joints)
        }
        for (j, a) in right.enumerated() {
            let minX = j == 0 ? cx + inner : notch.maxX + m.ear * CGFloat(j)
            let maxX = notch.maxX + m.ear * CGFloat(j + 1)
            var joints: NotchSlot.Edges = []
            if j < right.count - 1 { joints.insert(.right) }
            if j > 0 { joints.insert(.left) }
            slots[a.pid] = wing(a, role: .rightWing, minX: minX, maxX: maxX, joints: joints)
        }

        if !showers.isEmpty {
            let scale = max(1, frame.screen.scale)
            let k = CGFloat(showers.count)
            let floor = notch.width + 2 * m.ear
            let shared = min(max(showers.map { size($0, frame: frame).width }.max() ?? 0, floor), frame.usableWidth)
            // Equal widths on the pixel grid, so snapping can't make them differ.
            let w = ((shared - (k - 1) * m.splitSlit) / k * scale).rounded(.down) / scale
            let total = w * k + (k - 1) * m.splitSlit
            var x = ((cx - total / 2) * scale).rounded() / scale
            for a in showers {
                let bh = m.shoulder + size(a, frame: frame).bodyHeight
                let body = CGRect(x: x, y: top - menuBarDepth - bh, width: w, height: bh)
                slots[a.pid]?.bodyFrame = body
                slots[a.pid]?.bodyJoints = [.top]
                x += w + m.splitSlit
            }
        }
        for (pid, slot) in slots {
            slots[pid]?.visibleFrame = slot.bodyFrame.map { slot.frame!.union($0) } ?? slot.frame
        }
        return slots
    }

    // MARK: Merged

    /// Stacked slots in the user's order under one continuous black outline.
    /// - Shared width: the widest announced width for each app's resting mode (at least the quiet ears); while a part
    ///   is hovered (`focus`) the whole stack widens together to that app's expanded width, and only its part grows
    ///   taller (it is laid out open).
    /// - The open part keeps covering what was under the pointer when its hover began (`hoverHold`): its bottom edge
    ///   never rises above it and the stack never gets narrower than it. Moving down from an open part to the next
    ///   one hands the hover over; the upper part closes and would pull the lower one up from under the pointer, so
    ///   the lower part reaches down to where it was instead.
    /// - Top slot: attached to the notch, shared width (including the 6 pt flares), notch height + its body.
    /// - Lower slots: the top slot's body width (shared − 2 × flare), as tall as their body (at least
    ///   `minLowerSlotHeight`), and **fully tucked**: each one's rect starts just under the notch band and runs under
    ///   every slot above, so only bottom edges move, and a peer that's late to follow shows extra black, never the
    ///   desktop.
    /// - Levels: `levelOffset = −rank`; `stackHovered` moves the whole stack to the hovered level together.
    /// - Only the lowest slot casts a shadow. Square joints.
    /// Without a notch: stacked separate capsules (glass can't merge across windows) with a gap, same width.
    static func merged(_ members: [NotchDockAnnouncement], frame: Frame,
                       focus: NotchDockAnnouncement?) -> [Int32: NotchSlot] {
        let m = frame.metrics
        let scale = max(1, frame.screen.scale)
        var slots: [Int32: NotchSlot] = [:]
        let stackHovered = focus != nil
        let sizes = members.map { a -> (width: CGFloat, bodyHeight: CGFloat) in
            a.pid == focus?.pid ? size(a, frame: frame, mode: .expanded) : size(a, frame: frame)
        }
        let notched = frame.placement == .notch && frame.screen.notchRect != nil
        let floor = notched ? (frame.screen.notchRect?.width ?? 0) + 2 * m.ear : m.capsuleWidth
        var widest = max(sizes.map(\.width).max() ?? 0, floor)
        let focusIndex = members.firstIndex { $0.pid == focus?.pid }
        let hold = focus.flatMap { $0.isSticky ? $0.hoverHold : nil }.flatMap { $0.isEmpty ? nil : $0 }
        if let hold, let i = focusIndex {
            let inset = notched && i > 0 ? m.flare : 0
            widest = max(widest, 2 * (max(frame.centerX - hold.minX, hold.maxX - frame.centerX) + inset))
        }
        let rawWidth = min(widest, frame.usableWidth)
        // Snap the shared width to an even number of pixels and x to the grid so every slot shares edges exactly.
        let width = (rawWidth * scale / 2).rounded(.down) * 2 / scale
        let x = ((frame.centerX - width / 2) * scale).rounded() / scale
        let last = members.count - 1

        guard notched, let notch = frame.screen.notchRect else {
            var y = frame.anchorY
            for (i, (a, s)) in zip(members, sizes).enumerated() {
                var h = frame.band + s.bodyHeight
                if i == focusIndex, let hold { h = max(h, y - hold.minY) }
                slots[a.pid] = NotchSlot(role: .whole, placement: frame.placement,
                                         frame: CGRect(x: x, y: y - h, width: width, height: h), anchorY: frame.anchorY,
                                         levelOffset: -i, mayExpand: true, mayAsk: false, stackHovered: stackHovered,
                                         isOpen: i == focusIndex)
                y -= h + m.capsuleGap
            }
            return slots
        }

        let bandBottom = frame.anchorY - notch.height
        var bottom = frame.anchorY
        for (i, (a, s)) in zip(members, sizes).enumerated() {
            if i == 0 {
                let h = notch.height + s.bodyHeight
                bottom -= h
                if i == focusIndex, let hold { bottom = min(bottom, hold.minY) }
                slots[a.pid] = NotchSlot(role: .top, placement: .notch,
                                         frame: CGRect(x: x, y: bottom, width: width, height: frame.anchorY - bottom),
                                         anchorY: frame.anchorY, joints: [.bottom], levelOffset: 0, mayExpand: true,
                                         mayAsk: false, stackHovered: stackHovered, castsShadow: last == 0,
                                         isOpen: i == focusIndex)
            } else {
                let above = bottom
                bottom -= max(s.bodyHeight, m.minLowerSlotHeight)
                if i == focusIndex, let hold { bottom = min(bottom, hold.minY) }
                let rect = CGRect(x: x + m.flare, y: bottom, width: width - 2 * m.flare, height: bandBottom - bottom)
                slots[a.pid] = NotchSlot(role: i == last ? .bottom : .middle, placement: .notch, frame: rect,
                                         visibleFrame: CGRect(x: rect.minX, y: bottom, width: rect.width, height: above - bottom),
                                         anchorY: frame.anchorY, joints: i == last ? [.top] : [.top, .bottom],
                                         levelOffset: -i, mayExpand: true, mayAsk: false,
                                         stackHovered: stackHovered, castsShadow: i == last, isOpen: i == focusIndex)
            }
        }
        return slots
    }

    // MARK: Pixel grid

    static func snapped(_ slots: [Int32: NotchSlot], scale: CGFloat) -> [Int32: NotchSlot] {
        guard scale > 0 else { return slots }
        func snap(_ r: CGRect) -> CGRect {
            let minX = (r.minX * scale).rounded() / scale, maxX = (r.maxX * scale).rounded() / scale
            let minY = (r.minY * scale).rounded() / scale, maxY = (r.maxY * scale).rounded() / scale
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        return slots.mapValues { slot in
            var s = slot
            s.frame = s.frame.map(snap)
            s.bodyFrame = s.bodyFrame.map(snap)
            s.visibleFrame = s.visibleFrame.map(snap)
            s.anchorY = s.anchorY.map { ($0 * scale).rounded() / scale }
            return s
        }
    }
}
