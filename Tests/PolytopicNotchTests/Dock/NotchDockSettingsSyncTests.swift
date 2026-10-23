import Foundation
import Testing
@testable import PolytopicNotch

/// Sandboxed apps can't read the shared settings file, so the dock carries the settings in its messages.
@Suite("Dock settings over the wire (sandboxed apps)")
@MainActor
struct NotchDockSettingsSyncTests {
    private func sandboxedRig() -> DockRig {
        let rig = DockRig()
        rig.sandboxed = true
        return rig
    }

    @Test("a change in one app reaches apps that each keep their own copy")
    func changePropagates() async {
        let rig = sandboxedRig()
        let a = rig.add(Fx.captioner, pid: 101), b = rig.add(Fx.monitor, pid: 102)
        await rig.pump()
        a.setStyle(.split)
        a.setUrgentHold(.untilAnswered)
        await rig.pump()
        #expect(b.style == .split && b.urgentHold == .untilAnswered)
        b.setOrder([Fx.monitor, Fx.captioner])
        await rig.pump()
        #expect(a.order == [Fx.monitor, Fx.captioner])
    }

    @Test("a fresh app takes the dock's settings instead of resetting everyone to its defaults")
    func newcomerAdopts() async {
        let rig = sandboxedRig()
        let a = rig.add(Fx.captioner, pid: 101), b = rig.add(Fx.monitor, pid: 102)
        a.setStyle(.merged)
        await rig.pump()
        let c = rig.add(Fx.third, pid: 103)
        await rig.pump()
        #expect([a, b, c].allSatisfy { $0.style == .merged })
        // The newcomer is in its own order (joining isn't a write) and everyone lays it out after the listed apps.
        #expect(c.order.contains(Fx.third))
    }

    @Test("an app that wasn't running during a change catches up when it starts")
    func catchesUp() async {
        let rig = sandboxedRig()
        let a = rig.add(Fx.captioner, pid: 101)
        let b = rig.add(Fx.monitor, pid: 102, start: false)
        a.setStyle(.switcher)
        await rig.pump()
        #expect(b.style == .priority)
        b.start()
        await rig.pump()
        #expect(b.style == .switcher)
        #expect(a.style == .switcher)
    }

    @Test("equal settings post no replies: one change, then quiet")
    func noEcho() async {
        let rig = sandboxedRig()
        let a = rig.add(Fx.captioner, pid: 101), b = rig.add(Fx.monitor, pid: 102)
        await rig.pump()
        let before = (a.postedCount, b.postedCount)
        a.setStyle(.split)
        await rig.pump()
        #expect(a.postedCount == before.0 + 1)
        #expect(b.postedCount == before.1)
    }

    @Test("a block reaches every copy; a blocked app's own settings can't let it back in")
    func blockedCannotUnblockItself() async {
        let rig = sandboxedRig()
        let a = rig.add(Fx.captioner, pid: 101), b = rig.add(Fx.monitor, pid: 102), c = rig.add(Fx.third, pid: 103)
        await rig.pump()
        a.setBlocked(Fx.monitor, true)
        await rig.pump()
        #expect([a, b, c].allSatisfy { $0.blocked == [Fx.monitor] })
        #expect(a.peers[102] == nil && c.peers[102] == nil && b.peers.isEmpty)

        // A hostile blocked app rewrites its own copy and broadcasts it as the newest.
        rig.storages[102]?.set([String](), forKey: NotchDockSettings.Key.blocked)
        b.setStyle(.merged)
        await rig.pump()
        #expect(a.blocked == [Fx.monitor] && c.blocked == [Fx.monitor])
        #expect(a.style == .priority && c.style == .priority)
        #expect(a.peers[102] == nil)

        // The user lets it back in from another app.
        c.setBlocked(Fx.monitor, false)
        await rig.pump()
        #expect(a.peers[102] != nil && b.peers.keys.sorted() == [101, 103])
    }

    @Test("newest stamp wins, a tie goes to the greater writer, so every app picks the same snapshot")
    func ordering() {
        let t = Date(timeIntervalSinceReferenceDate: 1000)
        func s(_ at: Date, _ writer: String) -> NotchDockSharedSettings {
            NotchDockSharedSettings(style: "split", holdSeconds: 30, holdUntilAnswered: false, order: [], blocked: [],
                                    updatedAt: at, writer: writer)
        }
        #expect(s(t.addingTimeInterval(1), "a").isNewer(than: s(t, "z")))
        #expect(s(t, "b").isNewer(than: s(t, "a")))
        #expect(!s(t, "a").isNewer(than: s(t, "a")))
    }

    @Test("untrusted strings are capped and a stamp from the future is pulled back to now")
    func sanitized() {
        let now = Date(timeIntervalSinceReferenceDate: 1000)
        let long = String(repeating: "x", count: 300)
        let raw = NotchDockSharedSettings(style: String(repeating: "s", count: 40), holdSeconds: .infinity,
                                          holdUntilAnswered: false, order: (0..<100).map { "app\($0)" } + [long, ""],
                                          blocked: ["a", "a", long], updatedAt: now.addingTimeInterval(86_400 * 365),
                                          writer: long)
        let s = raw.sanitized(now: now)
        #expect(s.style == "priority")
        #expect(s.holdSeconds == 30)
        #expect(s.order.count == NotchDockSharedSettings.maxApps && !s.order.contains(long))
        #expect(s.blocked == ["a"])
        #expect(s.updatedAt == now)
        #expect(s.writer.count == NotchDockSharedSettings.maxIDLength)
        #expect(raw.sanitized(now: now).holdSeconds == 30)
        var slow = raw
        slow.holdSeconds = 99_999
        #expect(slow.sanitized(now: now).holdSeconds == 3600)
    }

    @Test("joining isn't a write; every setter stamps")
    func stamps() {
        let storage = InMemoryNotchDockSettingsStorage()
        var clock = Date(timeIntervalSinceReferenceDate: 500)
        let s = NotchDockSettings(storage: storage, writer: Fx.captioner, now: { clock })
        s.register(appID: Fx.captioner)
        #expect(s.updatedAt == .distantPast)
        s.setStyle(.split)
        #expect(s.updatedAt == clock && s.snapshot.writer == Fx.captioner)
        clock = clock.addingTimeInterval(5)
        s.setBlocked([Fx.third])
        #expect(s.updatedAt == clock)
    }
}
