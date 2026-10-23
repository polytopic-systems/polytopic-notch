import Foundation
import Testing
@testable import PolytopicNotch

struct LiveItem: Identifiable, Equatable {
    let id: Int
    var text: String = ""
}

@MainActor
final class FakeLiveClock {
    var now = ContinuousClock.now
    func advance(_ seconds: Double) { now = now + .milliseconds(Int(seconds * 1000)) }
}

/// What the app publishes and what the list shows: held lists keep `shown`, count what's new on the live side,
/// resume, app holds, and detaching.
@MainActor
struct NotchLiveFeedTests {
    func items(_ ids: some Sequence<Int>) -> [LiveItem] { ids.map { LiveItem(id: $0) } }

    func feed(_ edge: NotchLiveEdge, clock: FakeLiveClock) -> NotchLiveFeed<LiveItem> {
        NotchLiveFeed(edge: edge, now: { clock.now })
    }

    @Test func liveShowsWhatIsPublished() {
        let clock = FakeLiveClock()
        let feed = feed(.top, clock: clock)
        feed.publish(items([3, 2, 1]))
        #expect(feed.shown.map(\.id) == [3, 2, 1])
        feed.publish(items([4, 3, 2]))
        #expect(feed.shown.map(\.id) == [4, 3, 2])
        #expect(feed.pendingNew == 0)
        #expect(!feed.isHeld)
    }

    @Test func heldKeepsShownAndCountsNewOnTheTop() {
        let clock = FakeLiveClock()
        let feed = feed(.top, clock: clock)
        feed.publish(items([5, 4, 3, 2, 1]))
        feed.actionHover(true, token: "row")
        feed.publish(items([7, 6, 5, 4, 3]))             // two new, 2 and 1 dropped off the far side
        #expect(feed.shown.map(\.id) == [5, 4, 3, 2, 1], "held: nothing moves")
        #expect(feed.pendingNew == 2)
        var changed = items([8, 7, 6, 5, 4])
        changed[3].text = "updated"                       // a shown item changing doesn't show while held either
        feed.publish(changed)
        #expect(feed.shown[0].text == "")
        #expect(feed.pendingNew == 3)
    }

    @Test func heldCountsNewAtTheBottom() {
        let clock = FakeLiveClock()
        let feed = feed(.bottom, clock: clock)
        feed.publish(items(1...5))
        feed.scrolled(atLiveEdge: false, moved: true)    // reading older lines
        feed.publish(items(3...9))                        // 6...9 new; 1, 2 dropped off the top
        #expect(feed.shown.map(\.id) == [1, 2, 3, 4, 5])
        #expect(feed.pendingNew == 4)
    }

    @Test(arguments: [NotchLiveEdge.top, .bottom])
    func pendingCounting(edge: NotchLiveEdge) {
        // Written newest-first; reversed for the bottom edge.
        func order(_ ids: [Int]) -> [LiveItem] { (edge == .top ? ids : ids.reversed()).map { LiveItem(id: $0) } }
        typealias Feed = NotchLiveFeed<LiveItem>
        #expect(Feed.pendingCount(shown: order([3, 2, 1]), latest: order([3, 2, 1]), edge: edge) == 0)
        #expect(Feed.pendingCount(shown: order([3, 2, 1]), latest: order([5, 4, 3, 2, 1]), edge: edge) == 2)
        #expect(Feed.pendingCount(shown: order([3, 2, 1]), latest: order([5, 4, 3]), edge: edge) == 2, "the far side dropped")
        #expect(Feed.pendingCount(shown: order([3, 2, 1]), latest: order([5, 4, 2, 1]), edge: edge) == 2,
                "the live-most shown item is gone: count from the next one still there")
        #expect(Feed.pendingCount(shown: order([3, 2, 1]), latest: order([9, 8]), edge: edge) == 2, "nothing shown is left")
        #expect(Feed.pendingCount(shown: [], latest: order([2, 1]), edge: edge) == 2)
        #expect(Feed.pendingCount(shown: order([3, 2, 1]), latest: [], edge: edge) == 0)
    }

    @Test func resumeAppliesTheLatestAndScrollsToTheEdge() {
        let clock = FakeLiveClock()
        let feed = feed(.bottom, clock: clock)
        feed.publish(items(1...3))
        feed.scrolled(atLiveEdge: false, moved: true)
        feed.publish(items(1...6))
        let request = feed.scrollToEdgeRequest
        feed.resumeLive()
        #expect(!feed.isHeld)
        #expect(feed.shown.map(\.id) == [1, 2, 3, 4, 5, 6])
        #expect(feed.pendingNew == 0)
        #expect(feed.scrollToEdgeRequest == request + 1)
    }

    @Test func appHoldsHoldAndReleaseAfterTheGrace() {
        let clock = FakeLiveClock()
        let feed = feed(.top, clock: clock)
        feed.publish(items([1]))
        feed.hold(.app("result"))
        feed.publish(items([2, 1]))
        #expect(feed.shown.map(\.id) == [1])
        #expect(feed.pendingNew == 1)
        clock.advance(3)
        feed.release(.app("result"))
        #expect(feed.isHeld, "the grace runs first")
        clock.advance(1.1)
        feed.checkDeadline()
        #expect(feed.isHeld)
        clock.advance(0.1)
        feed.checkDeadline()
        #expect(!feed.isHeld)
        #expect(feed.shown.map(\.id) == [2, 1])
    }

    @Test func pointerTokensKeepTheHoldAcrossRows() {
        let clock = FakeLiveClock()
        let feed = feed(.top, clock: clock)
        feed.actionHover(true, token: "a")
        feed.actionHover(true, token: "b")                // entered the next row before leaving the first
        feed.actionHover(false, token: "a")
        #expect(feed.follow.reasons == [.pointer])
        #expect(feed.follow.nextDeadline == nil)
        feed.actionHover(false, token: "b")
        #expect(feed.follow.nextDeadline != nil)
        feed.actionHover(false, token: "b")               // a second leave changes nothing
        #expect(feed.state == .held([]))
    }

    @Test func theMenuHolds() {
        let clock = FakeLiveClock()
        let feed = feed(.top, clock: clock)
        feed.menu(open: true)
        #expect(feed.state == .held([.menu]))
        feed.menu(open: true)
        feed.menu(open: false)
        #expect(feed.state == .held([]))
        feed.menu(open: false)
        #expect(feed.follow.nextDeadline != nil)
    }

    @Test func readingReturnsAfterIdleAndAsksForTheEdge() {
        let clock = FakeLiveClock()
        let feed = feed(.bottom, clock: clock)
        feed.publish(items(1...3))
        feed.scrolled(atLiveEdge: false, moved: true)
        feed.publish(items(1...4))
        let request = feed.scrollToEdgeRequest
        clock.advance(4.9)
        feed.checkDeadline()
        #expect(feed.isHeld)
        clock.advance(0.1)
        feed.checkDeadline()
        #expect(!feed.isHeld)
        #expect(feed.shown.count == 4)
        #expect(feed.scrollToEdgeRequest == request + 1)
    }

    @Test func detachResetsToLiveAndCancelsTheCheck() {
        let clock = FakeLiveClock()
        let feed = feed(.top, clock: clock)
        feed.publish(items([1]))
        feed.attach()
        feed.hold(.app("x"))
        feed.publish(items([2, 1]))
        feed.release(.app("x"))
        #expect(feed.hasScheduledCheck, "a return is pending while the list shows")
        feed.detach()
        #expect(!feed.isAttached)
        #expect(!feed.hasScheduledCheck)
        #expect(!feed.isHeld)
        #expect(feed.shown.map(\.id) == [2, 1])
    }

    @Test func nothingIsScheduledWithoutAView() {
        let clock = FakeLiveClock()
        let feed = feed(.top, clock: clock)
        feed.hold(.pointer)
        feed.release(.pointer)
        #expect(feed.follow.nextDeadline != nil)
        #expect(!feed.hasScheduledCheck, "the pill is closed: nothing runs")
        feed.attach()
        #expect(feed.hasScheduledCheck, "the view appeared: the pending return is scheduled")
        feed.detach()
    }

    @Test func resetAfterATabSwitchIsLive() {
        let clock = FakeLiveClock()
        let feed = feed(.top, clock: clock)
        feed.publish(items([1]))
        feed.hold(.menu)
        feed.publish(items([2, 1]))
        feed.reset()
        #expect(!feed.isHeld)
        #expect(feed.shown.map(\.id) == [2, 1])
        #expect(feed.pendingNew == 0)
    }
}
