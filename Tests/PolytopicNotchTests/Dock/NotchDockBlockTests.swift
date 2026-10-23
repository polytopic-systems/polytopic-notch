import Foundation
import Testing
@testable import PolytopicNotch

@Suite("Dock block list")
@MainActor
struct NotchDockBlockTests {
    @Test("blocking an app drops it everywhere, on its own side too; unblocking lets it back in")
    func blockAndUnblock() async {
        let rig = DockRig()
        defer { rig.store.remove() }
        let a = rig.add(Fx.captioner, pid: 101), b = rig.add(Fx.monitor, pid: 102), c = rig.add(Fx.third, pid: 103)
        await rig.pump()
        #expect(a.peers.keys.sorted() == [102, 103])

        a.setBlocked(Fx.monitor, true)
        await rig.pump()
        #expect(a.peers.keys.sorted() == [103])
        #expect(c.peers.keys.sorted() == [101])
        #expect(b.peers.isEmpty)
        #expect([a, b, c].allSatisfy { $0.blocked == [Fx.monitor] })
        // Still blocked when it announces again.
        b.update { $0.want = .notice }
        await rig.pump()
        #expect(a.peers[102] == nil && c.peers[102] == nil)

        c.setBlocked(Fx.monitor, false)
        await rig.pump()
        #expect(a.peers.keys.sorted() == [102, 103])
        #expect(b.peers.keys.sorted() == [101, 103])
    }

    @Test("the block list applies to what a pid really is, not only to what it claims")
    func claimedIDDoesNotDodge() async {
        let rig = DockRig()
        defer { rig.store.remove() }
        rig.realAppIDs[102] = Fx.monitor
        let a = rig.add(Fx.captioner, pid: 101)
        a.setBlocked(Fx.monitor, true)
        _ = rig.add("com.example.Disguised", pid: 102)
        await rig.pump()
        #expect(a.peers.isEmpty)
    }

    @Test("an app can't block itself")
    func notSelf() async {
        let rig = DockRig()
        defer { rig.store.remove() }
        let a = rig.add(Fx.captioner, pid: 101)
        a.setBlocked(Fx.captioner, true)
        #expect(a.blocked.isEmpty)
    }

    @Test("blocked apps stay in the Settings list so they can be unblocked")
    func listed() {
        let rows = NotchDockAppList.rows(order: [Fx.captioner], me: Fx.captioner, peers: [], blocked: [Fx.monitor])
        #expect(rows == [Fx.captioner, Fx.monitor])
    }
}
