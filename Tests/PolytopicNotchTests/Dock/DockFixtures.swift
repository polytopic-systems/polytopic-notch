import CoreGraphics
import Foundation
import Testing
@testable import PolytopicNotch

enum Fx {
    static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// A 14-inch MacBook Pro: 1512×982 points, a 186×32 notch centred at x = 756, Retina.
    static let notched = NotchDockScreen(displayID: 1, screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                      notchRect: CGRect(x: 663, y: 950, width: 186, height: 32), menuBarHeight: 32,
                                      scale: 2)
    /// An external display to the right, no notch, 1×.
    static let external = NotchDockScreen(displayID: 2, screenFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
                                       notchRect: nil, menuBarHeight: 25, scale: 1)

    static let captioner = "com.example.Captioner"
    static let monitor = "com.example.Monitor"
    static let third = "com.example.Third"
    static let order = [captioner, monitor, third]

    static let captions = NotchDockSizes(quiet: .init(width: 266, bodyHeight: 0), showing: .init(width: 500, bodyHeight: 60),
                                    asking: .init(width: 440, bodyHeight: 40), expanded: .init(width: 560, bodyHeight: 300))
    static let posts = NotchDockSizes(quiet: .init(width: 266, bodyHeight: 0), showing: .init(width: 360, bodyHeight: 30),
                                 asking: .init(width: 440, bodyHeight: 80), expanded: .init(width: 480, bodyHeight: 240))

    static func app(_ appID: String, pid: Int32, want: NotchWant = .quiet, since: TimeInterval = 0,
                    mode: NotchMode = .quiet, display: UInt32 = 1, sizes: NotchDockSizes = captions,
                    hovered: Bool = false, menuOpen: Bool = false, claim: NotchSwitcherClaim? = nil,
                    stranger: Bool = false, bar: CGRect? = nil,
                    styles: [NotchSharingStyle] = NotchSharingStyle.allCases) -> NotchDockAnnouncement {
        NotchDockAnnouncement(appID: appID, pid: pid, instance: "i\(pid)", displayID: display, want: want,
                         since: t0.addingTimeInterval(since), mode: mode, sizes: sizes, hovered: hovered,
                         menuOpen: menuOpen, switcherClaim: claim, seesStranger: stranger, barRect: bar,
                         supportedStyles: styles.map(\.rawValue), symbol: "sym\(pid)")
    }

    static func solve(_ style: NotchSharingStyle, _ ps: [NotchDockAnnouncement], order: [String] = order,
                      hold: NotchUrgentHold = .standard, at: TimeInterval = 10) -> [Int32: NotchSlot] {
        solve(style, notched, ps, order: order, hold: hold, at: at)
    }

    static func solve(_ style: NotchSharingStyle, _ geometry: NotchDockScreen, _ ps: [NotchDockAnnouncement],
                      order: [String] = order, hold: NotchUrgentHold = .standard, at: TimeInterval = 10) -> [Int32: NotchSlot] {
        NotchDockLayout.solve(style: style, screen: geometry, participants: ps, order: order, urgentHold: hold,
                         now: t0.addingTimeInterval(at))
    }

    static func visible(_ slots: [Int32: NotchSlot]) -> Set<Int32> { Set(slots.filter { $0.value.isVisible }.keys) }
}

extension NotchSlot {
    /// The level the panel controller gives a slot that's at the notch (not below a stranger): 27 − rank, or 100 − rank
    /// while the stack (or the app itself) is hovered.
    func testLevel(selfHovered: Bool) -> Int {
        (stackHovered || selfHovered ? NotchDockMetrics.standard.hoveredLevel : NotchDockMetrics.standard.normalLevel) + levelOffset
    }
}

/// Trusts a fixed set of pids and counts how often each was asked.
final class CountingDockTrust: NotchDockTrust, @unchecked Sendable {
    private let lock = NSLock()
    private var trusted: Set<Int32>
    private var _calls: [Int32: Int] = [:]

    init(trusted: Set<Int32>) { self.trusted = trusted }

    func calls(for pid: Int32) -> Int { lock.withLock { _calls[pid, default: 0] } }

    func verify(pid: Int32) async -> Bool {
        lock.withLock {
            _calls[pid, default: 0] += 1
            return trusted.contains(pid)
        }
    }
}

@MainActor
final class TestDefaults {
    let defaults = InMemoryNotchDockSettingsStorage()
    func remove() {}
}

/// Several meshes in one process on the in-memory bus.
@MainActor
final class DockRig {
    let bus = InMemoryNotchDockBus()
    let store = TestDefaults()
    let trust: CountingDockTrust
    var meshes: [NotchDock] = []
    var watchers: [ManualNotchDockProcessWatcher] = []
    var clock = Fx.t0
    /// Each app gets its own settings storage, as sandboxed apps do (each reads its own container's copy).
    var sandboxed = false
    var storages: [Int32: InMemoryNotchDockSettingsStorage] = [:]
    /// What each pid really is (the block list checks it); unknown pids are nil.
    var realAppIDs: [Int32: String] = [:]

    init(trusted: Set<Int32> = [101, 102, 103]) { trust = CountingDockTrust(trusted: trusted) }

    @discardableResult
    func add(_ appID: String, pid: Int32, start: Bool = true) -> NotchDock {
        let watcher = ManualNotchDockProcessWatcher()
        let storage = sandboxed ? InMemoryNotchDockSettingsStorage() : store.defaults
        storages[pid] = storage
        let mesh = NotchDock(appID: appID, pid: pid, instance: "inst\(pid)", symbol: "s\(pid)",
                             channel: bus.makeChannel(), trust: trust,
                             settings: NotchDockSettings(storage: storage, writer: appID), processes: watcher,
                             now: { [unowned self] in self.clock },
                             appIDForPID: { [unowned self] in self.realAppIDs[$0] })
        meshes.append(mesh)
        watchers.append(watcher)
        if start { mesh.start() }
        return mesh
    }

    /// Delivers until quiet, including messages posted after async trust checks.
    func pump() async {
        for _ in 0..<50 {
            let delivered = bus.flush()
            #expect(delivered < 10_000, "a message loop")
            for m in meshes { await m.waitForVerifications() }
            if !bus.hasPending { return }
        }
    }

    deinit {}
}
