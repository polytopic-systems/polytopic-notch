import CoreGraphics
import Foundation
import Testing
@testable import PolytopicNotch

@Suite("Layout: solo and Priority")
struct PriorityLayoutTests {
    @Test("one participant gets today's solo pill in every style", arguments: NotchSharingStyle.allCases)
    func solo(style: NotchSharingStyle) {
        let slots = Fx.solve(style, [Fx.app(Fx.captioner, pid: 1, want: .live, mode: .showing)])
        let s = slots[1]!
        #expect(s.role == .whole)
        #expect(s.placement == .notch)
        #expect(s.frame == CGRect(x: 506, y: 890, width: 500, height: 92))
        #expect(s.mayExpand)
        #expect(s.switcherDots.isEmpty)
    }

    @Test("idle solo pill is at least the notch wide and hangs from the top")
    func soloIdle() {
        let s = Fx.solve(.priority, [Fx.app(Fx.captioner, pid: 1, want: .quiet)])[1]!
        #expect(s.frame == CGRect(x: 623, y: 950, width: 266, height: 32))
    }

    @Test("higher want wins; the other steps aside fully")
    func higherWant() {
        let slots = Fx.solve(.priority, [Fx.app(Fx.captioner, pid: 1, want: .live), Fx.app(Fx.monitor, pid: 2, want: .notice)])
        #expect(Fx.visible(slots) == [1])
        #expect(slots[2]!.role == .hidden && !slots[2]!.mayExpand && !slots[2]!.mayAsk)
        #expect(slots[2]!.frame == nil)
    }

    @Test("ties: earlier since, then user order; order hot-swap flips the tie")
    func ties() {
        let a = Fx.app(Fx.captioner, pid: 1, want: .notice, since: 5)
        let b = Fx.app(Fx.monitor, pid: 2, want: .notice, since: 3)
        #expect(Fx.visible(Fx.solve(.priority, [a, b])) == [2])
        let c = Fx.app(Fx.monitor, pid: 2, want: .notice, since: 5)
        #expect(Fx.visible(Fx.solve(.priority, [a, c])) == [1])
        #expect(Fx.visible(Fx.solve(.priority, [a, c], order: [Fx.monitor, Fx.captioner])) == [2])
        // Apps missing from the order come after listed ones, by app id.
        #expect(Fx.visible(Fx.solve(.priority, [a, c], order: [Fx.monitor])) == [2])
        #expect(Fx.visible(Fx.solve(.priority, [a, c], order: [])) == [1])
    }

    @Test("nobody wants anything: the first app in user order owns the hover zone")
    func allNone() {
        let slots = Fx.solve(.split, [Fx.app(Fx.monitor, pid: 2, want: .none), Fx.app(Fx.captioner, pid: 1, want: .none)])
        #expect(Fx.visible(slots) == [1])
    }

    @Test("urgent within its hold beats live and may ask; after the hold it competes as notice")
    func urgentHold() {
        let live = Fx.app(Fx.captioner, pid: 1, want: .live, since: 0)
        let urgent = Fx.app(Fx.monitor, pid: 2, want: .urgent, since: 10, mode: .asking, sizes: Fx.posts)
        let within = Fx.solve(.priority, [live, urgent], at: 39.9)
        #expect(Fx.visible(within) == [2])
        #expect(within[2]!.mayAsk)
        #expect(within[2]!.frame!.height == 112) // notch 32 + prompt body 80
        let after = Fx.solve(.priority, [live, urgent], at: 40)
        #expect(Fx.visible(after) == [1])
        #expect(!after[2]!.mayAsk)
        // Expired urgent still beats a quiet app (notice > quiet), and then it may ask in the notch.
        let quiet = Fx.app(Fx.captioner, pid: 1, want: .quiet)
        let alone = Fx.solve(.priority, [quiet, urgent], at: 100)
        #expect(Fx.visible(alone) == [2])
        #expect(alone[2]!.mayAsk)
    }

    @Test("until answered: the hold never runs out")
    func untilAnswered() {
        let live = Fx.app(Fx.captioner, pid: 1, want: .live)
        let urgent = Fx.app(Fx.monitor, pid: 2, want: .urgent, since: 10, mode: .asking)
        let slots = Fx.solve(.priority, [live, urgent], hold: .untilAnswered, at: 10 + 86_400)
        #expect(Fx.visible(slots) == [2])
        #expect(slots[2]!.mayAsk)
    }

    @Test("sticky while hovered or a menu is open: a new urgent goes to its floating window",
          arguments: [(true, false), (false, true)])
    func sticky(hovered: Bool, menuOpen: Bool) {
        let owner = Fx.app(Fx.captioner, pid: 1, want: .live, mode: .expanded, hovered: hovered, menuOpen: menuOpen)
        let urgent = Fx.app(Fx.monitor, pid: 2, want: .urgent, since: 9, mode: .asking)
        for style in [NotchSharingStyle.priority, .switcher, .split] {
            let slots = Fx.solve(style, [owner, urgent])
            #expect(Fx.visible(slots) == [1], "\(style)")
            #expect(slots[1]!.role == .whole)
            #expect(slots[1]!.mayExpand)
            #expect(!slots[2]!.mayAsk)
            // notch 32 + expanded body 300, and in Switcher the dots' 26 pt row between them
            #expect(slots[1]!.frame!.height == (style == .switcher ? 358 : 332), "\(style)")
        }
        // Merged keeps the stack while hovered (by design); the question still waits in its floating window.
        let merged = Fx.solve(.merged, [owner, urgent])
        #expect(Fx.visible(merged) == [1, 2])
        #expect(merged.values.allSatisfy { $0.stackHovered && !$0.mayAsk })
        // Hover ends: the urgent (still within hold) takes over.
        let released = Fx.app(Fx.captioner, pid: 1, want: .live)
        #expect(Fx.visible(Fx.solve(.priority, [released, urgent])) == [2])
    }

    @Test("two urgents: the earlier asks in the notch, the later one may not")
    func twoUrgents() {
        let a = Fx.app(Fx.captioner, pid: 1, want: .urgent, since: 6, mode: .asking)
        let b = Fx.app(Fx.monitor, pid: 2, want: .urgent, since: 4, mode: .asking)
        for style in NotchSharingStyle.allCases {
            let slots = Fx.solve(style, [a, b])
            #expect(Fx.visible(slots) == [2])
            #expect(slots[2]!.mayAsk)
            #expect(!slots[1]!.mayAsk)
        }
        // Same moment: user order decides.
        let c = Fx.app(Fx.monitor, pid: 2, want: .urgent, since: 6, mode: .asking)
        #expect(Fx.visible(Fx.solve(.priority, [a, c])) == [1])
    }
}

@Suite("Layout: strangers, bars, displays, fallbacks")
struct EnvironmentLayoutTests {
    @Test("a stranger seen by any peer moves everyone below the notch, in every style",
          arguments: NotchSharingStyle.allCases)
    func stranger(style: NotchSharingStyle) {
        let a = Fx.app(Fx.captioner, pid: 1, want: .live)
        let b = Fx.app(Fx.monitor, pid: 2, want: .notice, stranger: true)
        let slots = Fx.solve(style, [a, b])
        // Swift Testing (Swift 6.4) mis-evaluates `#expect(cgFloat == 950 - 5)`: compare against plain literals.
        #expect(slots.values.compactMap { $0.frame?.maxY }.max() == 945) // notch bottom 950 - shared gap 5
        for slot in slots.values where slot.isVisible {
            #expect(slot.placement == .belowNotch)
            #expect(slot.frame!.maxY <= 945)
            #expect(slot.role == .whole) // capsules: notch-attached shapes can't be used below a stranger
        }
    }

    @Test("bars reported by different peers are unioned; everyone hangs below the union")
    func barUnion() {
        let a = Fx.app(Fx.captioner, pid: 1, want: .live, bar: CGRect(x: 500, y: 920, width: 600, height: 24))
        let b = Fx.app(Fx.monitor, pid: 2, want: .notice, bar: CGRect(x: 700, y: 910, width: 300, height: 30))
        let slots = Fx.solve(.priority, [a, b])
        #expect(slots[1]!.placement == .belowNotch)
        #expect(slots[1]!.frame!.maxY == 905)
    }

    @Test("bars outside the dock's reach or on another screen are ignored")
    func barIgnored() {
        let far = Fx.app(Fx.captioner, pid: 1, want: .live, bar: CGRect(x: 0, y: 940, width: 100, height: 22))
        let other = Fx.app(Fx.monitor, pid: 2, want: .notice, bar: CGRect(x: 2000, y: 1030, width: 400, height: 22))
        let slots = Fx.solve(.priority, [far, other])
        #expect(slots[1]!.placement == .notch)
        #expect(slots[1]!.frame!.maxY == 982)
    }

    @Test("participants on another display don't take part")
    func displayMismatch() {
        let a = Fx.app(Fx.captioner, pid: 1, want: .quiet)
        let b = Fx.app(Fx.monitor, pid: 2, want: .urgent, mode: .asking, display: 2)
        let here = Fx.solve(.split, [a, b])
        #expect(here.keys.sorted() == [1])
        #expect(here[1]!.role == .whole)
        let there = Fx.solve(.split, Fx.external, [a, b])
        #expect(there.keys.sorted() == [2])
        #expect(there[2]!.placement == .menuBar)
        #expect(Fx.solve(.split, Fx.external, [a]).isEmpty)
    }

    @Test("a style some participant can't draw falls back to Priority for everyone")
    func unsupportedStyle() {
        let a = Fx.app(Fx.captioner, pid: 1, want: .live)
        let b = Fx.app(Fx.monitor, pid: 2, want: .notice, styles: [.priority, .switcher])
        let slots = Fx.solve(.split, [a, b])
        #expect(Fx.visible(slots) == [1])
        #expect(slots[1]!.role == .whole)
        #expect(Fx.visible(Fx.solve(.merged, [a, b])) == [1])
        // Switcher is supported by both: dots show.
        #expect(Fx.solve(.switcher, [a, b])[1]!.switcherDots.count == 2)
    }

    @Test("fewer than two apps showing anything: today's solo layout", arguments: [NotchSharingStyle.split, .merged])
    func fewerThanTwo(style: NotchSharingStyle) {
        let a = Fx.app(Fx.captioner, pid: 1, want: .live, mode: .showing)
        let b = Fx.app(Fx.monitor, pid: 2, want: .none, mode: .hidden)
        let slots = Fx.solve(style, [a, b])
        #expect(Fx.visible(slots) == [1])
        #expect(slots[1]!.role == .whole)
        #expect(slots[1]!.frame == CGRect(x: 506, y: 890, width: 500, height: 92))
    }

    @Test("rects are snapped to the pixel grid")
    func pixelGrid() {
        var g = Fx.notched
        g.notchRect = CGRect(x: 663.3, y: 950, width: 185.3, height: 32)
        for style in [NotchSharingStyle.split, .merged] {
            let slots = Fx.solve(style, g, [Fx.app(Fx.captioner, pid: 1, want: .live, mode: .showing),
                                            Fx.app(Fx.monitor, pid: 2, want: .quiet),
                                            Fx.app(Fx.third, pid: 3, want: .notice, mode: .showing, sizes: Fx.posts)])
            for slot in slots.values {
                for r in [slot.frame, slot.bodyFrame, slot.visibleFrame].compactMap({ $0 }) {
                    for v in [r.minX, r.maxX, r.minY, r.maxY] { #expect((v * 2).rounded() == v * 2) }
                }
            }
        }
    }
}

@Suite("Layout: Switcher")
struct SwitcherLayoutTests {
    let a = Fx.app(Fx.captioner, pid: 1, want: .live)
    let b = Fx.app(Fx.monitor, pid: 2, want: .notice)
    let c = Fx.app(Fx.third, pid: 3, want: .quiet)

    @Test("Priority plus dots for every docked app, in user order")
    func dots() {
        let slots = Fx.solve(.switcher, [c, b, a])
        #expect(Fx.visible(slots) == [1])
        #expect(slots[1]!.switcherDots.map(\.pid) == [1, 2, 3])
        #expect(slots[1]!.switcherDots.map(\.isCurrent) == [true, false, false])
        #expect(slots[1]!.switcherDots[1].symbol == "sym2")
        let swapped = Fx.solve(.switcher, [a, b, c], order: [Fx.third, Fx.captioner, Fx.monitor])
        #expect(swapped[1]!.switcherDots.map(\.pid) == [3, 1, 2])
    }

    @Test("clicking a dot hands the notch to that app while hovered; latest claim wins")
    func claim() {
        var hoveredA = a
        hoveredA.hovered = true
        hoveredA.switcherClaim = NotchSwitcherClaim(pid: 2, at: Fx.t0.addingTimeInterval(5))
        var slots = Fx.solve(.switcher, [hoveredA, b, c])
        #expect(Fx.visible(slots) == [2])
        #expect(slots[2]!.mayExpand)
        #expect(slots[2]!.switcherDots.first { $0.isCurrent }?.pid == 2)
        // Now b is hovered (its pill is under the pointer) and clicks c's dot later.
        var hoveredB = b
        hoveredB.hovered = true
        hoveredB.switcherClaim = NotchSwitcherClaim(pid: 3, at: Fx.t0.addingTimeInterval(6))
        slots = Fx.solve(.switcher, [hoveredA, hoveredB, c])
        #expect(Fx.visible(slots) == [3])
        // Back to a by a later click.
        var hoveredC = c
        hoveredC.hovered = true
        hoveredC.switcherClaim = NotchSwitcherClaim(pid: 1, at: Fx.t0.addingTimeInterval(7))
        slots = Fx.solve(.switcher, [a, hoveredB, hoveredC])
        #expect(Fx.visible(slots) == [1])
    }

    @Test("a claim holds until its claimer clears it, hovered or not; it is ignored in other styles")
    func claimHolds() {
        // Right after the click nobody may be hovered (the claimer's pill is gone, the target's hover not begun):
        // the target stays open. 0.2.1 dropped the claim here and flashed the claimer back under the pointer.
        var claimer = a
        claimer.sizes.expanded = NotchDockSize(width: 600, bodyHeight: 300)
        claimer.switcherClaim = NotchSwitcherClaim(pid: 2, at: Fx.t0)
        let slots = Fx.solve(.switcher, [claimer, b])
        #expect(Fx.visible(slots) == [2])
        #expect(slots[2]!.isOpen, "the target is laid out open, as if hovered")
        #expect(slots[2]!.frame!.width == 600, "at least as wide as the claimer's open pill, so the dot stays inside")
        #expect(slots[2]!.frame!.height == 358, "its own expanded height, with the dots' row")
        claimer.hovered = true
        #expect(Fx.visible(Fx.solve(.priority, [claimer, b])) == [1])
        // A claim for an app that isn't here (quit) is ignored.
        claimer.switcherClaim = NotchSwitcherClaim(pid: 9, at: Fx.t0)
        #expect(Fx.visible(Fx.solve(.switcher, [claimer, b])) == [1])
    }
}

@Suite("Layout: Split")
struct SplitLayoutTests {
    @Test("two quiet apps: one 40 pt ear each side, exactly today's quiet ears, join hidden in the notch")
    func twoApps() {
        let slots = Fx.solve(.split, [Fx.app(Fx.monitor, pid: 2), Fx.app(Fx.captioner, pid: 1)])
        let l = slots[1]!, r = slots[2]!
        #expect(l.role == .leftWing && r.role == .rightWing)
        #expect(l.frame == CGRect(x: 623, y: 950, width: 130, height: 32))
        #expect(r.frame == CGRect(x: 759, y: 950, width: 130, height: 32))
        #expect(l.frame!.union(r.frame!).width == 266) // notch 186 + two 40 pt ears
        #expect(r.frame!.minX - l.frame!.maxX == 6)     // the slit, inside the notch (663…849)
        #expect(l.frame!.maxX > 663 && r.frame!.minX < 849)
        #expect(l.joints.isEmpty && r.joints.isEmpty)
        // Quiet neck capped at ear height (32) - ear corner radius (10).
        #expect(l.neckDepth == 22 && r.neckDepth == 22)
        #expect(l.mayExpand && r.mayExpand && !l.mayAsk)
        #expect(l.castsShadow && l.levelOffset == 0 && !l.stackHovered)
    }

    @Test("user order hot-swap moves apps between sides")
    func hotSwap() {
        let ps = [Fx.app(Fx.captioner, pid: 1), Fx.app(Fx.monitor, pid: 2)]
        #expect(Fx.solve(.split, ps)[1]!.role == .leftWing)
        let swapped = Fx.solve(.split, ps, order: [Fx.monitor, Fx.captioner])
        #expect(swapped[1]!.role == .rightWing)
        #expect(swapped[2]!.role == .leftWing)
    }

    @Test("three apps: first two on the left (first outermost), third on the right, one ear each")
    func threeApps() {
        let slots = Fx.solve(.split, [Fx.app(Fx.captioner, pid: 1), Fx.app(Fx.monitor, pid: 2), Fx.app(Fx.third, pid: 3)])
        #expect(slots[1]!.frame == CGRect(x: 583, y: 950, width: 40, height: 32))
        #expect(slots[1]!.joints == [.right])
        #expect(slots[2]!.frame == CGRect(x: 623, y: 950, width: 130, height: 32))
        #expect(slots[2]!.joints == [.left])
        #expect(slots[3]!.frame == CGRect(x: 759, y: 950, width: 130, height: 32))
        #expect(slots[3]!.joints.isEmpty)
        #expect([slots[1]!, slots[2]!].allSatisfy { $0.role == .leftWing })
    }

    @Test("two showing: equal halves of the shared width with a 6 pt slit, in user order; ears kept")
    func twoShowing() {
        let slots = Fx.solve(.split, [Fx.app(Fx.captioner, pid: 1, want: .live, mode: .showing),
                                      Fx.app(Fx.monitor, pid: 2, want: .notice, mode: .showing, sizes: Fx.posts)])
        // Shared width 500 (widest showing); (500 - 6) / 2 = 247 each; bodies start below the menu bar (32) and
        // include the 10 pt shoulder.
        #expect(slots[1]!.bodyFrame == CGRect(x: 506, y: 880, width: 247, height: 70))
        #expect(slots[2]!.bodyFrame == CGRect(x: 759, y: 910, width: 247, height: 40))
        #expect(slots[2]!.bodyFrame!.minX - slots[1]!.bodyFrame!.maxX == 6)
        #expect(slots[1]!.frame == CGRect(x: 623, y: 950, width: 130, height: 32))
        #expect(slots[1]!.neckDepth == 32)
        #expect(slots[1]!.bodyJoints == [.top])
    }

    @Test("one showing, the other quiet: the body spreads over the full shared width; back to halves after")
    func oneShowingSpreads() {
        let one = Fx.solve(.split, [Fx.app(Fx.captioner, pid: 1, want: .live, mode: .showing),
                                    Fx.app(Fx.monitor, pid: 2, want: .quiet)])
        #expect(one[1]!.bodyFrame == CGRect(x: 506, y: 880, width: 500, height: 70))
        #expect(one[2]!.bodyFrame == nil)
        #expect(one[2]!.frame == CGRect(x: 759, y: 950, width: 130, height: 32))
        #expect(one[2]!.neckDepth == 22)
        // The right-hand app shows alone: same full width, its ear stays on the right.
        let right = Fx.solve(.split, [Fx.app(Fx.captioner, pid: 1, want: .quiet),
                                      Fx.app(Fx.monitor, pid: 2, want: .notice, mode: .showing)])
        #expect(right[2]!.bodyFrame == CGRect(x: 506, y: 880, width: 500, height: 70))
        #expect(right[2]!.role == .rightWing)
        let both = Fx.solve(.split, [Fx.app(Fx.captioner, pid: 1, want: .live, mode: .showing),
                                     Fx.app(Fx.monitor, pid: 2, want: .notice, mode: .showing)])
        #expect(both.values.compactMap(\.bodyFrame).map(\.width) == [247, 247])
    }

    @Test("bodies never exceed the screen and keep equal widths")
    func bodiesFit() {
        var wide = Fx.captions
        wide.showing = NotchDockSize(width: 1200, bodyHeight: 60)
        let ps = (1...3).map { Fx.app([Fx.captioner, Fx.monitor, Fx.third][$0 - 1], pid: Int32($0), want: .live,
                                      mode: .showing, sizes: wide) }
        let bodies = Fx.solve(.split, ps).values.compactMap(\.bodyFrame)
        #expect(bodies.count == 3)
        #expect(bodies.allSatisfy { $0.minX >= 16 && $0.maxX <= 1496 })
        #expect(Set(bodies.map(\.width)) == [396])
    }

    @Test("hovering one app expands it over the whole notch (expanding is exclusive in Split)")
    func hoverExclusive() {
        let slots = Fx.solve(.split, [Fx.app(Fx.captioner, pid: 1, want: .live, mode: .showing),
                                      Fx.app(Fx.monitor, pid: 2, mode: .expanded, hovered: true)])
        #expect(Fx.visible(slots) == [2])
        #expect(slots[2]!.role == .whole)
        #expect(slots[2]!.frame == CGRect(x: 476, y: 650, width: 560, height: 332))
    }

    @Test("while one app's pill is open, the other's ear hands it over; an open pill covers what it was hovered at")
    func handoffEars() throws {
        var hovered = Fx.app(Fx.monitor, pid: 2, want: .notice, mode: .showing, sizes: Fx.posts, hovered: true)
        // Hovered at the outer edge of its half (the right body ends at x = 1006); its expanded width is only 480.
        hovered.hoverHold = CGRect(x: 759, y: 920, width: 247, height: 30)
        hovered.hoverSince = Fx.t0
        let slots = Fx.solve(.split, [Fx.app(Fx.captioner, pid: 1, want: .live, mode: .showing), hovered])
        let open = try #require(slots[2]?.frame)
        #expect(slots[2]!.role == .whole && slots[2]!.isOpen)
        #expect(open.minX <= 759 && open.maxX >= 1006 && open.minY <= 920, "covers the hold")
        #expect(open.width == 500)
        // The left app is hidden, but its ear beside the notch takes the open pill back.
        #expect(slots[1]!.role == .hidden)
        #expect(slots[1]!.handoffFrame == CGRect(x: 623, y: 950, width: 40, height: 32))
        #expect(slots[2]!.handoffFrame == nil)
        // Not while a question holds the notch, and not in Priority.
        let urgent = Fx.solve(.split, [Fx.app(Fx.captioner, pid: 1, want: .live, mode: .showing),
                                       Fx.app(Fx.monitor, pid: 2, want: .urgent, since: 5, mode: .asking)])
        #expect(urgent[1]!.handoffFrame == nil)
        let priority = Fx.solve(.priority, [Fx.app(Fx.captioner, pid: 1, want: .live, mode: .showing), hovered])
        #expect(priority[1]!.handoffFrame == nil)
    }

    @Test("two hovered at once (a handover): the one hovered first stays open until it lets go")
    func incumbent() {
        var left = Fx.app(Fx.captioner, pid: 1, want: .live, mode: .showing, hovered: true)
        var right = Fx.app(Fx.monitor, pid: 2, want: .notice, mode: .showing, hovered: true)
        left.hoverSince = Fx.t0.addingTimeInterval(2)
        right.hoverSince = Fx.t0.addingTimeInterval(1)
        #expect(Fx.visible(Fx.solve(.split, [left, right])) == [2])
        right.hoverSince = Fx.t0.addingTimeInterval(3)
        #expect(Fx.visible(Fx.solve(.split, [left, right])) == [1])
        // A menu holder wins whatever the times.
        right.menuOpen = true
        #expect(Fx.visible(Fx.solve(.split, [left, right])) == [2])
    }

    @Test("non-notch screen: separate capsules side by side")
    func capsules() {
        let slots = Fx.solve(.split, Fx.external, [Fx.app(Fx.captioner, pid: 1, display: 2),
                                                   Fx.app(Fx.monitor, pid: 2, display: 2)])
        #expect(slots[1]!.frame == CGRect(x: 2203, y: 1019, width: 266, height: 30))
        #expect(slots[2]!.frame == CGRect(x: 2475, y: 1019, width: 266, height: 30))
        #expect(slots.values.allSatisfy { $0.role == .whole && $0.placement == .menuBar && $0.joints.isEmpty })
    }
}

@Suite("Layout: Merged")
struct MergedLayoutTests {
    let captions = Fx.app(Fx.captioner, pid: 1, want: .live, mode: .showing)
    let strip = Fx.app(Fx.monitor, pid: 2, want: .quiet)

    @Test("two apps: top attached at the shared width; lower slot at the body width, fully tucked")
    func twoApps() {
        let slots = Fx.solve(.merged, [captions, strip])
        let top = slots[1]!, low = slots[2]!
        #expect(top.role == .top && top.levelOffset == 0 && top.joints == [.bottom])
        #expect(top.frame == CGRect(x: 506, y: 890, width: 500, height: 92))
        #expect(low.role == .bottom && low.levelOffset == -1 && low.joints == [.top])
        // Width 500 - 2 × 6 flare; visible 24 pt below the top slot; rect reaches up to the notch band (950).
        #expect(low.frame == CGRect(x: 512, y: 866, width: 488, height: 84))
        #expect(low.frame!.maxY == 950)
        // One shadow, on the lowest slot.
        #expect(!top.castsShadow && low.castsShadow)
        #expect(top.testLevel(selfHovered: false) == 27 && low.testLevel(selfHovered: false) == 26)
    }

    @Test("full tuck: a lower slot covers everything between the notch band and its own bottom")
    func fullTuck() {
        for lines in [20.0, 40, 60, 120] {
            var sizes = Fx.captions
            sizes.showing = NotchDockSize(width: 500, bodyHeight: lines)
            let slots = Fx.solve(.merged, [Fx.app(Fx.captioner, pid: 1, want: .live, mode: .showing, sizes: sizes), strip])
            #expect(slots[2]!.frame!.maxY == 950)
            #expect(slots[2]!.frame!.minY == slots[1]!.frame!.minY - 24)
        }
    }

    @Test("three apps: top, middle, bottom in user order; order hot-swap restacks")
    func threeApps() {
        let ps = [captions, strip, Fx.app(Fx.third, pid: 3, want: .notice, mode: .showing, sizes: Fx.posts)]
        let slots = Fx.solve(.merged, ps)
        #expect(slots[1]!.role == .top)
        #expect(slots[2]!.role == .middle && slots[2]!.joints == [.top, .bottom] && slots[2]!.levelOffset == -1)
        #expect(slots[2]!.frame == CGRect(x: 512, y: 866, width: 488, height: 84))
        #expect(slots[3]!.role == .bottom && slots[3]!.levelOffset == -2)
        #expect(slots[3]!.frame == CGRect(x: 512, y: 836, width: 488, height: 114))
        #expect(slots.values.filter(\.castsShadow).count == 1 && slots[3]!.castsShadow)

        let swapped = Fx.solve(.merged, ps, order: [Fx.third, Fx.monitor, Fx.captioner])
        #expect(swapped[3]!.role == .top)
        #expect(swapped[3]!.frame == CGRect(x: 506, y: 920, width: 500, height: 62))
        #expect(swapped[1]!.role == .bottom)
    }

    @Test("hovering a lower part: the whole stack widens to the expanded width and rises together, order kept")
    func hoverLower() {
        let hovered = Fx.app(Fx.monitor, pid: 2, want: .quiet, mode: .expanded, hovered: true)
        let slots = Fx.solve(.merged, [captions, hovered])
        let top = slots[1]!, low = slots[2]!
        #expect(top.frame == CGRect(x: 476, y: 890, width: 560, height: 92))   // wider, not taller
        #expect(low.frame == CGRect(x: 482, y: 590, width: 548, height: 360))  // wider and taller (300 body)
        #expect(top.stackHovered && low.stackHovered)
        #expect(top.testLevel(selfHovered: false) == 100)
        #expect(low.testLevel(selfHovered: true) == 99)
        #expect(top.mayExpand && low.mayExpand)
        #expect(low.isOpen && !top.isOpen, "only the hovered part is laid out open")
    }

    @Test("the open part sizes by its expanded size and the others by their resting mode, whatever mode they announce")
    func restMode() {
        // The top app still announces `expanded` (it was open a moment ago) but rests in `showing`: it isn't open.
        var top = Fx.app(Fx.captioner, pid: 1, want: .live, mode: .expanded)
        top.restMode = .showing
        let hovered = Fx.app(Fx.monitor, pid: 2, want: .quiet, mode: .quiet, hovered: true)
        let slots = Fx.solve(.merged, [top, hovered])
        #expect(slots[1]!.frame == CGRect(x: 476, y: 890, width: 560, height: 92))
        #expect(slots[2]!.frame == CGRect(x: 482, y: 590, width: 548, height: 360))
    }

    @Test("moving down from an open part: the lower part keeps reaching down to where it was hovered")
    func holdBelow() {
        // Monitor's row was at 604…628 under Captioner's open part when the pointer reached it.
        var low = Fx.app(Fx.monitor, pid: 2, want: .quiet, sizes: Fx.posts, hovered: true)
        low.hoverHold = CGRect(x: 482, y: 604, width: 548, height: 24)
        low.hoverSince = Fx.t0
        let slots = Fx.solve(.merged, [captions, low])
        #expect(slots[1]!.frame == CGRect(x: 476, y: 890, width: 560, height: 92), "the top part closed")
        #expect(slots[2]!.visibleFrame == CGRect(x: 482, y: 604, width: 548, height: 286), "down to the hold")
        #expect(slots[2]!.isOpen)
        // Two parts hovered at once: the earlier stays open, so the stack doesn't move until it lets go.
        var top = Fx.app(Fx.captioner, pid: 1, want: .live, mode: .showing, hovered: true)
        top.hoverSince = Fx.t0.addingTimeInterval(-1)
        let both = Fx.solve(.merged, [top, low])
        #expect(both[1]!.isOpen && !both[2]!.isOpen)
    }

    @Test("hovering the top part: it grows taller, the lower one moves down with it at the same width")
    func hoverTop() {
        let hovered = Fx.app(Fx.captioner, pid: 1, want: .live, mode: .expanded, hovered: true)
        let slots = Fx.solve(.merged, [hovered, strip])
        #expect(slots[1]!.frame == CGRect(x: 476, y: 650, width: 560, height: 332))
        #expect(slots[2]!.frame == CGRect(x: 482, y: 626, width: 548, height: 324))
        #expect(slots[2]!.testLevel(selfHovered: false) == 99)
    }

    @Test("a menu held open counts as hovered for the stack")
    func menuOpen() {
        let menu = Fx.app(Fx.monitor, pid: 2, want: .quiet, mode: .expanded, menuOpen: true)
        let slots = Fx.solve(.merged, [captions, menu])
        #expect(slots.values.allSatisfy { $0.stackHovered })
    }

    @Test("quiet apps only: shared width is today's quiet ears")
    func quietOnly() {
        let slots = Fx.solve(.merged, [Fx.app(Fx.captioner, pid: 1, sizes: .init()), Fx.app(Fx.monitor, pid: 2, sizes: .init())])
        #expect(slots[1]!.frame == CGRect(x: 623, y: 950, width: 266, height: 32))
        #expect(slots[2]!.frame == CGRect(x: 629, y: 926, width: 254, height: 24))
    }

    @Test("x and width are on the device pixel grid, so the slots share edges exactly", arguments: [1.0, 2.0, 3.0])
    func pixelGrid(scale: Double) {
        var g = Fx.notched
        g.scale = CGFloat(scale)
        g.notchRect = CGRect(x: 663.37, y: 950, width: 185.3, height: 32)
        var sizes = Fx.captions
        sizes.showing = NotchDockSize(width: 501.3, bodyHeight: 60)
        let slots = Fx.solve(.merged, g, [Fx.app(Fx.captioner, pid: 1, want: .live, mode: .showing, sizes: sizes), strip])
        let top = slots[1]!.frame!, low = slots[2]!.frame!
        for v in [top.minX, top.width, low.minX, low.width] {
            #expect((v * CGFloat(scale)).rounded() == v * CGFloat(scale))
        }
        #expect(low.minX - top.minX == 6 && top.maxX - low.maxX == 6)
    }

    @Test("an urgent question takes the whole notch; the stack returns after the hold")
    func urgentExclusive() {
        let ps = [captions, Fx.app(Fx.monitor, pid: 2, want: .urgent, since: 5, mode: .asking, sizes: Fx.posts)]
        let asking = Fx.solve(.merged, ps)
        #expect(Fx.visible(asking) == [2])
        #expect(asking[2]!.mayAsk && asking[2]!.role == .whole)
        let later = Fx.solve(.merged, ps, at: 60)
        #expect(Fx.visible(later) == [1, 2])
        #expect(!later[2]!.mayAsk)
    }

    @Test("non-notch screen: stacked separate capsules with a 6 pt gap, same width, each with its own glass")
    func capsules() {
        let slots = Fx.solve(.merged, Fx.external, [Fx.app(Fx.captioner, pid: 1, display: 2),
                                                    Fx.app(Fx.monitor, pid: 2, display: 2)])
        #expect(slots[1]!.frame == CGRect(x: 2339, y: 1019, width: 266, height: 30))
        #expect(slots[2]!.frame == CGRect(x: 2339, y: 983, width: 266, height: 30))
        #expect(slots.values.allSatisfy { $0.role == .whole })
        #expect(slots[1]!.levelOffset == 0 && slots[2]!.levelOffset == -1)
    }
}
