import CoreGraphics
import Foundation
import Testing
@testable import PolytopicNotch

@Suite("Dock on the in-memory channel")
@MainActor
struct NotchMeshTests {
    @Test("two docks find each other, including a late joiner")
    func lateJoin() async {
        let rig = DockRig()
        defer { rig.store.remove() }
        let a = rig.add(Fx.captioner, pid: 101)
        await rig.pump()
        #expect(a.peers.isEmpty)
        a.update { $0.want = .live; $0.mode = .showing }
        await rig.pump()
        let b = rig.add(Fx.monitor, pid: 102)
        await rig.pump()
        #expect(a.peers.keys.sorted() == [102])
        #expect(b.peers.keys.sorted() == [101])
        #expect(b.peers[101]?.want == .live)
        #expect(a.excludedPIDs == [102])
        // Both registered in the shared order, in start order.
        #expect(a.order == [Fx.captioner, Fx.monitor] || b.order == [Fx.captioner, Fx.monitor])
    }

    @Test("three docks agree on one layout; reorder hot-swaps everyone")
    func threeAgreeAndReorder() async {
        let rig = DockRig()
        defer { rig.store.remove() }
        let a = rig.add(Fx.captioner, pid: 101), b = rig.add(Fx.monitor, pid: 102), c = rig.add(Fx.third, pid: 103)
        a.setStyle(.split)
        for m in [a, b, c] { m.update { $0.want = .quiet; $0.mode = .quiet; $0.displayID = 1 } }
        await rig.pump()
        a.setOrder([Fx.captioner, Fx.monitor, Fx.third])
        await rig.pump()
        let layouts = [a, b, c].map { $0.layout(for: Fx.notched) }
        #expect(layouts.allSatisfy { $0 == layouts[0] })
        #expect(layouts[0][101]?.role == .leftWing && layouts[0][103]?.role == .rightWing)
        #expect([a, b, c].allSatisfy { $0.style == .split })

        let before = b.revision
        c.setOrder([Fx.third, Fx.monitor, Fx.captioner])
        await rig.pump()
        #expect(b.revision > before)
        #expect(a.order == [Fx.third, Fx.monitor, Fx.captioner])
        let swapped = [a, b, c].map { $0.layout(for: Fx.notched) }
        #expect(swapped.allSatisfy { $0 == swapped[0] })
        #expect(swapped[0][103]?.role == .leftWing && swapped[0][101]?.role == .rightWing)
    }

    @Test("a peer that quits is dropped, with its trust verdict")
    func quit() async {
        let rig = DockRig()
        defer { rig.store.remove() }
        let a = rig.add(Fx.captioner, pid: 101)
        _ = rig.add(Fx.monitor, pid: 102)
        await rig.pump()
        var left: [Int32] = []
        a.onPeerLeft = { left.append($0) }
        #expect(rig.trust.calls(for: 102) == 1)
        rig.watchers[0].simulateExit(102)
        #expect(a.peers.isEmpty)
        #expect(left == [102])
        // A new process reusing the pid is checked again.
        rig.meshes[1].sayHello()
        await rig.pump()
        #expect(rig.trust.calls(for: 102) == 2)
    }

    @Test("stop posts bye; peers drop that instance only")
    func bye() async {
        let rig = DockRig()
        defer { rig.store.remove() }
        let a = rig.add(Fx.captioner, pid: 101), b = rig.add(Fx.monitor, pid: 102)
        await rig.pump()
        b.stop()
        await rig.pump()
        #expect(a.peers.isEmpty)
        #expect(b.peers.isEmpty && !b.isRunning)
    }

    @Test("untrusted senders are never admitted and are checked once per pid")
    func untrusted() async {
        let rig = DockRig(trusted: [101])
        defer { rig.store.remove() }
        let a = rig.add(Fx.captioner, pid: 101), stranger = rig.add("com.example.Spoof", pid: 666)
        a.update { $0.displayID = 1 }
        stranger.update { $0.displayID = 1 }
        await rig.pump()
        for _ in 0..<5 {
            stranger.update { $0.want = $0.want == .urgent ? .live : .urgent }
            await rig.pump()
        }
        #expect(a.peers.isEmpty)
        #expect(rig.trust.calls(for: 666) == 1)
        #expect(a.layout(for: Fx.notched).keys.sorted() == [101])
    }

    @Test("idle docks post nothing; unchanged updates don't announce")
    func idleIsSilent() async {
        let rig = DockRig()
        defer { rig.store.remove() }
        let a = rig.add(Fx.captioner, pid: 101), b = rig.add(Fx.monitor, pid: 102)
        a.update { $0.want = .live; $0.mode = .showing; $0.sizes = Fx.captions }
        await rig.pump()
        let posted = rig.bus.log.count
        let revisions = (a.revision, b.revision)
        for _ in 0..<20 {
            a.update { $0.want = .live; $0.mode = .showing; $0.sizes = Fx.captions }
            b.update { _ in }
            await rig.pump()
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(rig.bus.log.count == posted)
        #expect((a.revision, b.revision) == revisions)
        #expect(a.pendingHoldTimers == 0 && b.pendingHoldTimers == 0)
        // One real change: exactly one announce.
        a.update { $0.hovered = true }
        await rig.pump()
        #expect(rig.bus.log.count == posted + 1)
    }

    @Test("since follows want, so peers see when a want started")
    func sinceFollowsWant() async {
        let rig = DockRig()
        defer { rig.store.remove() }
        let a = rig.add(Fx.captioner, pid: 101), b = rig.add(Fx.monitor, pid: 102)
        rig.clock = Fx.t0.addingTimeInterval(50)
        a.update { $0.want = .notice }
        rig.clock = Fx.t0.addingTimeInterval(60)
        a.update { $0.mode = .showing }
        await rig.pump()
        #expect(b.peers[101]?.since == Fx.t0.addingTimeInterval(50))
    }

    @Test("one one-shot timer per urgent participant; it fires when the hold ends")
    func holdTimer() async throws {
        let rig = DockRig()
        defer { rig.store.remove() }
        rig.clock = Date()
        let a = rig.add(Fx.captioner, pid: 101), b = rig.add(Fx.monitor, pid: 102)
        a.setUrgentHold(.seconds(1))
        await rig.pump()
        #expect(b.urgentHold == .seconds(1))
        rig.clock = Date().addingTimeInterval(-0.85) // the question started 0.85 s ago: 0.15 s of hold left
        b.update { $0.want = .urgent; $0.mode = .asking }
        rig.clock = Date()
        await rig.pump()
        #expect(a.pendingHoldTimers == 1 && b.pendingHoldTimers == 1)
        let before = a.revision
        for _ in 0..<40 where a.pendingHoldTimers > 0 { try await Task.sleep(for: .milliseconds(25)) }
        rig.clock = Date()
        #expect(a.pendingHoldTimers == 0)
        #expect(a.revision > before)
        // Until answered: no timer at all.
        a.setUrgentHold(.untilAnswered)
        await rig.pump()
        b.update { $0.want = .live }
        b.update { $0.want = .urgent }
        await rig.pump()
        #expect(a.pendingHoldTimers == 0 && b.pendingHoldTimers == 0)
    }

    @Test("a Switcher claim survives the handoff race and ends with the hover session")
    func claimLifetime() async {
        let rig = DockRig()
        defer { rig.store.remove() }
        let a = rig.add(Fx.captioner, pid: 101), b = rig.add(Fx.monitor, pid: 102)
        a.setStyle(.switcher)
        a.update { $0.want = .live; $0.hovered = true; $0.mode = .expanded; $0.displayID = 1 }
        b.update { $0.want = .notice; $0.displayID = 1 }
        await rig.pump()
        a.handNotch(to: 102)
        await rig.pump()
        #expect(b.layout(for: Fx.notched)[102]?.isVisible == true)
        // Handoff race: a sees the pointer leave its pill before b's "hovered" arrives. The claim must hold, so a
        // must not reappear and grab the hover back even if a is hovered again meanwhile.
        a.update { $0.hovered = false }
        #expect(a.me.switcherClaim != nil)
        a.update { $0.hovered = true }
        #expect(a.layout(for: Fx.notched)[102]?.isVisible == true)
        b.update { $0.hovered = true; $0.mode = .expanded }
        a.update { $0.hovered = false }
        await rig.pump()
        #expect(a.layout(for: Fx.notched)[102]?.isVisible == true)
        // Pointer leaves the dock: hover ends, a's host ends the session.
        b.update { $0.hovered = false; $0.mode = .quiet }
        a.endHoverSession()
        await rig.pump()
        #expect(b.peers[101]?.switcherClaim == nil)
        #expect(b.layout(for: Fx.notched)[101]?.isVisible == true)
        #expect(a.layout(for: Fx.notched) == b.layout(for: Fx.notched))
    }

    @Test("an unknown style written by a newer app reads as Priority everywhere")
    func unknownStyle() async {
        let rig = DockRig()
        defer { rig.store.remove() }
        let a = rig.add(Fx.captioner, pid: 101), b = rig.add(Fx.monitor, pid: 102)
        a.setStyle(.merged)
        await rig.pump()
        #expect(b.style == .merged)
        rig.store.defaults.set("orbit", forKey: "notch.sharingStyle")
        a.setOrder([Fx.captioner, Fx.monitor]) // any write pings
        await rig.pump()
        #expect(a.style == .priority && b.style == .priority)
    }
}
