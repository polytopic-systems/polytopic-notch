import Foundation
import Testing
@testable import PolytopicNotch

/// The hold/return algorithm on a fake clock: every reason, every deadline (and not a moment before), restarts,
/// reset, and the return from reading that scrolls back to the edge.
struct NotchLiveFollowTests {
    typealias Follow = NotchLiveFollow
    let t0 = ContinuousClock.now

    func at(_ seconds: Double) -> ContinuousClock.Instant { t0 + .milliseconds(Int(seconds * 1000)) }

    @Test func theDefaultTimings() {
        #expect(Follow.Timing.standard.actionGrace == .milliseconds(1200))
        #expect(Follow.Timing.standard.readingIdle == .seconds(5))
        let follow = Follow()
        #expect(follow.state == .live)
        #expect(follow.atLiveEdge)
        #expect(follow.nextDeadline == nil)
    }

    @Test(arguments: [Follow.Reason.pointer, .menu, .app("result")])
    func aReasonHoldsUntilReleasedThenTheGracePasses(reason: Follow.Reason) {
        var follow = Follow()
        follow.hold(reason, now: at(0))
        #expect(follow.state == .held([reason]))
        #expect(follow.nextDeadline == nil, "nothing returns while a reason holds")
        do { let result = follow.advance(now: at(60)); #expect(!result) }
        follow.release(reason, now: at(10))
        #expect(follow.state == .held([]))
        #expect(follow.nextDeadline == at(11.2))
        do { let result = follow.advance(now: at(11.199)); #expect(!result, "not before the grace") }
        #expect(follow.isHeld)
        do { let result = follow.advance(now: at(11.2)); #expect(result) }
        #expect(follow.state == .live)
        var copy = follow
        do { let result = copy.takeScrollBack(); #expect(!result, "at the edge already: nothing to scroll") }
    }

    @Test func movingBetweenActionsRestartsTheGrace() {
        var follow = Follow()
        follow.hold(.pointer, now: at(0))
        follow.release(.pointer, now: at(1))
        #expect(follow.nextDeadline == at(2.2))
        follow.hold(.pointer, now: at(2))                 // the next row, before the grace ran out
        #expect(follow.nextDeadline == nil)
        do { let result = follow.advance(now: at(2.2)); #expect(!result) }
        follow.release(.pointer, now: at(3))
        #expect(follow.nextDeadline == at(4.2), "the grace starts again, in full")
        do { let result = follow.advance(now: at(4.2)); #expect(result) }
    }

    @Test func severalReasonsReturnOnlyWhenTheLastGoes() {
        var follow = Follow()
        follow.hold(.pointer, now: at(0))
        follow.hold(.menu, now: at(0.5))
        follow.hold(.app("result"), now: at(0.6))
        follow.release(.pointer, now: at(1))
        follow.release(.app("result"), now: at(2))
        #expect(follow.state == .held([.menu]))
        #expect(follow.nextDeadline == nil)
        follow.release(.menu, now: at(3))
        #expect(follow.nextDeadline == at(4.2))
        follow.release(.menu, now: at(4))
        #expect(follow.nextDeadline == at(4.2), "releasing what isn't held changes nothing")
    }

    @Test func releasingWhileLiveDoesNothing() {
        var follow = Follow()
        follow.release(.pointer, now: at(0))
        #expect(follow.state == .live)
        #expect(follow.nextDeadline == nil)
        follow.hold(.reading, now: at(0))
        #expect(follow.state == .live, "reading comes from scrolling, not from hold")
    }

    @Test func scrollingAwayHoldsWhileReadingAndReturnsAfterIdle() {
        var follow = Follow()
        follow.scrolled(atLiveEdge: false, now: at(0))
        #expect(follow.state == .held([.reading]))
        #expect(follow.nextDeadline == at(5))
        follow.scrolled(atLiveEdge: false, now: at(3))    // still reading, scrolled a bit more
        #expect(follow.nextDeadline == at(8), "every movement starts the idle wait again")
        do { let result = follow.advance(now: at(7.999)); #expect(!result) }
        #expect(follow.isHeld)
        do { let result = follow.advance(now: at(8)); #expect(result) }
        #expect(follow.state == .live)
        #expect(follow.atLiveEdge)
        do { let result = follow.takeScrollBack(); #expect(result, "the return scrolls the list back to its live edge") }
        do { let result = follow.takeScrollBack(); #expect(!result, "once") }
    }

    @Test func scrollingBackToTheEdgeByHandIsLiveAtOnce() {
        var follow = Follow()
        follow.scrolled(atLiveEdge: false, now: at(0))
        follow.scrolled(atLiveEdge: true, now: at(1))
        #expect(follow.state == .live)
        #expect(follow.nextDeadline == nil)
        do { let result = follow.takeScrollBack(); #expect(!result) }
    }

    @Test func scrollingBackToTheEdgeOnAnActionWaitsForThePointer() {
        var follow = Follow()
        follow.scrolled(atLiveEdge: false, now: at(0))
        follow.hold(.pointer, now: at(1))
        #expect(follow.nextDeadline == nil, "reading on an action: no idle return")
        follow.scrolled(atLiveEdge: true, now: at(2))
        #expect(follow.state == .held([.pointer]))
        follow.release(.pointer, now: at(3))
        #expect(follow.nextDeadline == at(4.2), "at the edge: the action grace")
        do { let result = follow.advance(now: at(4.2)); #expect(result) }
    }

    @Test func aReasonWhileReadingStopsTheIdleWaitUntilItGoes() {
        var follow = Follow()
        follow.scrolled(atLiveEdge: false, now: at(0))
        follow.hold(.menu, now: at(4))
        do { let result = follow.advance(now: at(5)); #expect(!result, "the menu opened before the idle wait ran out") }
        follow.release(.menu, now: at(10))
        #expect(follow.state == .held([.reading]))
        #expect(follow.nextDeadline == at(15), "still away from the edge: the reading wait, in full")
        follow.scrolled(atLiveEdge: false, now: at(12))
        #expect(follow.nextDeadline == at(17))
        do { let result = follow.advance(now: at(17)); #expect(result) }
        do { let result = follow.takeScrollBack(); #expect(result) }
    }

    @Test func movementWhileHeldByAnActionAndAwayDefersTheWait() {
        var follow = Follow()
        follow.hold(.pointer, now: at(0))
        follow.scrolled(atLiveEdge: false, now: at(1))
        #expect(follow.state == .held([.pointer, .reading]))
        #expect(follow.nextDeadline == nil)
    }

    @Test func viewReportsWithoutMovementOnlyCountWhenTheEdgeChanges() {
        var follow = Follow()
        follow.scrolled(atLiveEdge: true, moved: false, now: at(0))
        #expect(follow.state == .live)
        follow.scrolled(atLiveEdge: false, moved: false, now: at(1))
        #expect(follow.state == .held([.reading]), "the view found the list away from its edge")
        follow.scrolled(atLiveEdge: false, moved: false, now: at(3))
        #expect(follow.nextDeadline == at(6), "a report without movement doesn't restart the wait")
    }

    @Test func resumeIsLiveAtOnceWhateverHoldsIt() {
        var follow = Follow()
        follow.hold(.app("result"), now: at(0))
        follow.hold(.pointer, now: at(0))
        follow.scrolled(atLiveEdge: false, now: at(1))
        follow.resume()
        #expect(follow.state == .live)
        #expect(follow.reasons.isEmpty)
        #expect(follow.atLiveEdge)
        #expect(follow.nextDeadline == nil)
        do { let result = follow.takeScrollBack(); #expect(result) }
    }

    @Test func resetIsLiveAtTheEdgeAndKeepsTheTiming() {
        var follow = Follow(timing: .init(actionGrace: .milliseconds(300), readingIdle: .seconds(2)))
        follow.scrolled(atLiveEdge: false, now: at(0))
        follow.hold(.menu, now: at(0))
        follow.reset()
        #expect(follow.state == .live)
        #expect(follow.atLiveEdge)
        #expect(follow.nextDeadline == nil)
        do { let result = follow.takeScrollBack(); #expect(!result) }
        #expect(follow.timing.actionGrace == .milliseconds(300))
        follow.hold(.pointer, now: at(1))
        follow.release(.pointer, now: at(1))
        #expect(follow.nextDeadline == at(1.3), "a changed timing is used")
    }

    @Test(arguments: [NotchLiveEdge.top, .bottom])
    func theLiveEdge(edge: NotchLiveEdge) {
        // 400 pt of content in a 100 pt view.
        let top = CGRect(x: 0, y: 0, width: 300, height: 100)
        let middle = CGRect(x: 0, y: 150, width: 300, height: 100)
        let bottom = CGRect(x: 0, y: 300, width: 300, height: 100)
        #expect(edge.contains(visible: top, contentHeight: 400) == (edge == .top))
        #expect(!edge.contains(visible: middle, contentHeight: 400))
        #expect(edge.contains(visible: bottom, contentHeight: 400) == (edge == .bottom))
        #expect(edge.contains(visible: top.offsetBy(dx: 0, dy: edge == .top ? 3 : -3).offsetBy(dx: 0, dy: edge == .top ? 0 : 300),
                              contentHeight: 400), "within 4 pt counts")
        #expect(edge.contains(visible: CGRect(x: 0, y: 0, width: 300, height: 100), contentHeight: 60), "short content is at both edges")
    }
}
