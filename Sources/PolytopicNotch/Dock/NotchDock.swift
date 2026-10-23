import AppKit
import Darwin
import Foundation
import Observation

/// This app's place in the dock: its own announcement, the trusted peers' announcements (by pid), and the shared
/// settings. It posts only when something changes (start, a field of the announcement, a settings write, a reply to
/// `hello`, stop), and runs no timers except one one-shot per urgent participant's hold.
///
/// An app makes one and hands it to its `NotchPanelController(…, dock:)`, which starts and stops it with the pill,
/// keeps the announcement current and places the pill from `slot(for:)`. Settings rows (`NotchDockSettingsRows`) take
/// the same dock.
///
///     let dock = NotchDock(symbol: "captions.bubble", log: .app)
///     let notch = NotchPanelController(content: content, settings: settings, neighbors: .shared, dock: dock)
@MainActor
@Observable
public final class NotchDock {
    public private(set) var me: NotchDockAnnouncement
    public private(set) var peers: [Int32: NotchDockAnnouncement] = [:]
    public private(set) var style: NotchSharingStyle = .priority
    public private(set) var urgentHold: NotchUrgentHold = .standard
    public private(set) var order: [String] = []
    /// App IDs the user blocked from the dock (shared by every docked app).
    public private(set) var blocked: Set<String> = []
    /// Bumped whenever a layout input changes, including an urgent hold running out. Observe this.
    public private(set) var revision = 0
    public private(set) var isRunning = false

    /// Pids the neighbor monitor must ignore: docked apps are never strangers.
    public var excludedPIDs: Set<Int32> { Set(peers.keys) }

    @ObservationIgnored private let channel: NotchDockChannel
    @ObservationIgnored private let trust: NotchDockTrust
    @ObservationIgnored private let settings: NotchDockSettings
    @ObservationIgnored private let processes: NotchDockProcessWatching
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let appIDForPID: @MainActor (Int32) -> String?
    @ObservationIgnored private let log: NotchLog
    @ObservationIgnored private var verdicts: [Int32: Bool] = [:]
    /// The app ID each trusted pid last announced, blocked or not (the block list checks it for settings too).
    @ObservationIgnored private var claimedAppIDs: [Int32: String] = [:]
    @ObservationIgnored private var buffered: [Int32: [NotchDockMessage]] = [:]
    @ObservationIgnored private var verifying: [Int32: Task<Void, Never>] = [:]
    @ObservationIgnored private var holdTimers: [Int32: (since: Date, task: Task<Void, Never>)] = [:]
    /// Messages this dock posted (tests and diagnostics).
    @ObservationIgnored public private(set) var postedCount = 0
    /// Called when a peer leaves (quit or bye). `NotchPanelController` sets it to forget the pid in the neighbor
    /// tracker; set it only for a dock that has no controller.
    @ObservationIgnored public var onPeerLeft: (@MainActor (Int32) -> Void)?

    /// - Parameters:
    ///   - appID: this app's bundle ID (the shared order and the block list are keyed by it).
    ///   - pid: this process (tests give several docks in one process their own).
    ///   - instance: random per start, so a `bye` from an earlier run of the same pid is told apart.
    ///   - symbol: SF Symbol for this app's Switcher dot.
    ///   - supportedStyles: styles this app can draw. Every package version from 0.2.0 draws all four.
    ///   - channel: how messages travel; `DistributedNotchDockChannel` in apps, `InMemoryNotchDockBus` in tests.
    ///   - trust: who may dock; `DeveloperIDTrust` by default.
    ///   - settings: the shared settings; the shared suite by default, in-memory storage in tests.
    ///   - processes: notices when a peer quits.
    ///   - log: where the dock writes what it does.
    ///   - now: the clock (tests).
    ///   - appIDForPID: the bundle ID of a running process, to apply the block list to what a pid really is, not only
    ///     what it claims.
    public init(appID: String = Bundle.main.bundleIdentifier ?? "unknown", pid: Int32 = getpid(),
                instance: String = UUID().uuidString, symbol: String,
                supportedStyles: [NotchSharingStyle] = NotchSharingStyle.allCases,
                channel: NotchDockChannel = DistributedNotchDockChannel(), trust: NotchDockTrust = DeveloperIDTrust(),
                settings: NotchDockSettings = NotchDockSettings(),
                processes: NotchDockProcessWatching = NotchDockProcessWatcher(),
                log: NotchLog = .silent, now: @escaping @MainActor () -> Date = { Date() },
                appIDForPID: @escaping @MainActor (Int32) -> String? = NotchDock.runningAppID) {
        self.channel = channel
        self.appIDForPID = appIDForPID
        self.trust = trust
        self.settings = settings
        self.processes = processes
        self.log = log
        self.now = now
        me = NotchDockAnnouncement(appID: appID, pid: pid, instance: instance, since: now(), mode: .hidden,
                                   supportedStyles: supportedStyles.map(\.rawValue), symbol: symbol)
        reloadSettings()
    }

    // MARK: Lifecycle

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        channel.open { [weak self] message in self?.receive(message) }
        settings.register(appID: me.appID)
        reloadSettings()
        post(.hello(me))
        // Peers with newer settings answer with theirs (a sandboxed app can't read the shared file).
        post(.style(pid: me.pid, settings: settings.snapshot))
        scheduleHold(for: me)
        bump()
        log.info("dock started (\(me.appID), style \(style.rawValue))")
    }

    public func stop() {
        guard isRunning else { return }
        post(.bye(pid: me.pid, instance: me.instance))
        channel.close()
        isRunning = false
        for task in verifying.values { task.cancel() }
        for timer in holdTimers.values { timer.task.cancel() }
        verifying = [:]
        holdTimers = [:]
        buffered = [:]
        for pid in Set(peers.keys).union(verdicts.keys) { processes.unwatch(pid: pid) }
        verdicts = [:]
        claimedAppIDs = [:]
        let left = Array(peers.keys)
        peers = [:]
        for pid in left { onPeerLeft?(pid) }
        bump()
        log.info("dock stopped")
    }

    /// Wake, screen change: ask everyone to announce again.
    public func sayHello() {
        guard isRunning else { return }
        post(.hello(me))
    }

    // MARK: Own state

    /// Changes this app's announcement; posts only if a field actually changed. `since` follows `want`.
    public func update(_ change: (inout NotchDockAnnouncement) -> Void) {
        var next = me
        change(&next)
        next.appID = me.appID
        next.pid = me.pid
        next.instance = me.instance
        if next.want != me.want { next.since = now() }
        guard next != me else { return }
        me = next
        scheduleHold(for: me)
        if isRunning { post(.announce(me)) }
        bump()
    }

    /// Switcher: the user clicked another app's dot in this app's open pill.
    public func handNotch(to pid: Int32) {
        update { $0.switcherClaim = NotchSwitcherClaim(pid: pid, at: now()) }
    }

    /// The pointer left the whole dock (the host's hover monitor knows). A Switcher claim lives for one hover session.
    /// It isn't cleared when nobody *seems* hovered: during a handoff the claimer stops being hovered before the
    /// target's "hovered" arrives, and clearing then would flash the claimer's pill back under the pointer.
    public func endHoverSession() {
        guard me.switcherClaim != nil else { return }
        update { $0.switcherClaim = nil }
    }

    // MARK: Shared settings

    public func setStyle(_ style: NotchSharingStyle) {
        settings.setStyle(style)
        settingsWritten()
    }

    public func setUrgentHold(_ hold: NotchUrgentHold) {
        settings.setUrgentHold(hold)
        settingsWritten()
    }

    public func setOrder(_ order: [String]) {
        settings.setOrder(order)
        settingsWritten()
    }

    /// Blocks or unblocks an app for every docked app. A blocked app is dropped at once; an unblocked one joins
    /// again when it next announces (this app says hello so it does).
    public func setBlocked(_ appID: String, _ isBlocked: Bool) {
        guard appID != me.appID else { return }
        var next = settings.blocked
        if isBlocked { next.insert(appID) } else { next.remove(appID) }
        settings.setBlocked(next)
        settingsWritten()
    }

    public static func runningAppID(_ pid: Int32) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    /// The hold's seconds, also while it's "until answered" (the Settings stepper).
    public var urgentHoldSeconds: Double {
        if case .seconds(let s) = urgentHold { return s }
        return settings.urgentHoldSeconds
    }

    /// Re-reads the shared settings (a Settings page appearing while this dock isn't running).
    public func refreshSharedSettings() {
        reloadSettings()
    }

    /// Whether an app in the order is running and docked right now (this app counts while its dock runs).
    public func isDocked(_ appID: String) -> Bool {
        (isRunning && appID == me.appID) || peers.values.contains { $0.appID == appID }
    }

    private func settingsWritten() {
        reloadSettings()
        // Posted even while stopped (posting needs no open channel), so running apps follow a change made in an app
        // whose pill is off.
        post(.style(pid: me.pid, settings: settings.snapshot))
    }

    private func reloadSettings() {
        let (s, h, o, b) = (settings.style, settings.urgentHold, settings.order, settings.blocked)
        guard s != style || h != urgentHold || o != order || b != blocked else { return }
        if s != style { log.info("dock style → \(s.rawValue)") }
        let unblocked = !blocked.subtracting(b).isEmpty
        style = s
        urgentHold = h
        order = o
        blocked = b
        // A blocked app leaves the dock on its own side too, so no two apps disagree on who is in it.
        for (pid, a) in peers where blocked.contains(me.appID) || isBlocked(pid: pid, claimed: a.appID) {
            log.notice("dock: \(a.appID) blocked by the user")
            removePeer(pid)
        }
        if unblocked { sayHello() }
        for a in participants { scheduleHold(for: a, force: true) }
        bump()
    }

    // MARK: Layout

    public var participants: [NotchDockAnnouncement] { [me] + peers.values.sorted { $0.pid < $1.pid } }

    /// Every docked app's slot on this screen (apps on other displays aren't in it).
    public func layout(for screen: NotchDockScreen, metrics: NotchDockMetrics = .standard) -> [Int32: NotchSlot] {
        NotchDockLayout.solve(style: style, screen: screen, participants: participants, order: order,
                              urgentHold: urgentHold, now: now(), metrics: metrics)
    }

    /// This app's slot if its announcement were `me` (the peers as they are): what the dock *will* give it once the
    /// change is out, e.g. whether a question that just arrived will be granted the notch.
    public func slot(for screen: NotchDockScreen, metrics: NotchDockMetrics = .standard,
                     ifMe me: NotchDockAnnouncement) -> NotchSlot? {
        var me = me
        me.pid = self.me.pid
        if me.want != self.me.want { me.since = now() }
        let others = peers.values.sorted { $0.pid < $1.pid }
        return NotchDockLayout.solve(style: style, screen: screen, participants: [me] + others, order: order,
                                     urgentHold: urgentHold, now: now(), metrics: metrics)[me.pid]
    }

    /// This app's own slot (nil if this app is on another display than `screen`).
    public func slot(for screen: NotchDockScreen, metrics: NotchDockMetrics = .standard) -> NotchSlot? {
        layout(for: screen, metrics: metrics)[me.pid]
    }

    // MARK: Receiving

    private func receive(_ message: NotchDockMessage) {
        let pid = message.senderPID
        guard isRunning, pid != me.pid, pid > 0 else { return }
        switch verdicts[pid] {
        case true?:
            handle(message)
        case false?:
            return
        case nil:
            var queue = buffered[pid, default: []]
            queue.append(message)
            buffered[pid] = Array(queue.suffix(8))
            guard verifying[pid] == nil else { return }
            verifying[pid] = Task { [weak self, trust] in
                let ok = await trust.verify(pid: pid)
                self?.finishVerification(pid: pid, trusted: ok)
            }
        }
    }

    private func finishVerification(pid: Int32, trusted: Bool) {
        verifying[pid] = nil
        guard isRunning else { return }
        verdicts[pid] = trusted
        if !trusted { log.notice("dock: ignoring pid \(pid): its code signature isn't trusted") }
        // Untrusted pids are watched too, so their verdict is forgotten (and the pid can be reused) on exit.
        processes.watch(pid: pid) { [weak self] in self?.processExited(pid) }
        let queue = buffered.removeValue(forKey: pid) ?? []
        if trusted { queue.forEach(handle) }
    }

    private func handle(_ message: NotchDockMessage) {
        // Blocked, this app hears nothing but settings, so it notices being let back in.
        if blocked.contains(me.appID) {
            if case .style(let pid, let shared) = message { receiveSettings(shared, from: pid) }
            return
        }
        switch message {
        case .hello(let a):
            upsert(a)
            reloadSettings()
            post(.announce(me))
        case .announce(let a):
            upsert(a)
        case .style(let pid, let shared):
            receiveSettings(shared, from: pid)
        case .bye(let pid, let instance):
            if peers[pid]?.instance == instance { removePeer(pid) }
        }
    }

    private func isBlocked(pid: Int32, claimed: String) -> Bool {
        guard !blocked.isEmpty else { return false }
        if blocked.contains(claimed) { return true }
        return appIDForPID(pid).map(blocked.contains) ?? false
    }

    private func receiveSettings(_ shared: NotchDockSharedSettings?, from pid: Int32) {
        // A blocked app's settings are ignored, so it can't let itself back in.
        guard !isBlocked(pid: pid, claimed: claimedAppIDs[pid] ?? "") else { return }
        guard let shared else { return reloadSettings() }
        let adoption = settings.adopt(shared)
        reloadSettings()
        // Ours is newer: answer, so the sender (a newcomer, or an app that missed a change) catches up.
        if adoption == .oursIsNewer { post(.style(pid: me.pid, settings: settings.snapshot)) }
    }

    private func upsert(_ a: NotchDockAnnouncement) {
        claimedAppIDs[a.pid] = a.appID
        guard !isBlocked(pid: a.pid, claimed: a.appID) else {
            removePeer(a.pid)
            return
        }
        guard peers[a.pid] != a else { return }
        if peers[a.pid] == nil { log.notice("dock: \(a.appID) joined (pid \(a.pid))") }
        peers[a.pid] = a
        scheduleHold(for: a)
        bump()
    }

    private func processExited(_ pid: Int32) {
        verdicts[pid] = nil
        claimedAppIDs[pid] = nil
        buffered[pid] = nil
        verifying.removeValue(forKey: pid)?.cancel()
        removePeer(pid)
    }

    private func removePeer(_ pid: Int32) {
        holdTimers.removeValue(forKey: pid)?.task.cancel()
        guard let gone = peers.removeValue(forKey: pid) else { return }
        log.notice("dock: \(gone.appID) left (pid \(pid))")
        onPeerLeft?(pid)
        bump()
    }

    // MARK: Urgent hold timers

    /// Pending hold one-shots (tests).
    public var pendingHoldTimers: Int { holdTimers.count }

    private func scheduleHold(for a: NotchDockAnnouncement, force: Bool = false) {
        let existing = holdTimers[a.pid]
        guard isRunning, a.want == .urgent, let deadline = urgentHold.deadline(since: a.since), deadline > now() else {
            existing?.task.cancel()
            holdTimers[a.pid] = nil
            return
        }
        if let existing, existing.since == a.since, !force { return }
        existing?.task.cancel()
        let delay = deadline.timeIntervalSince(now())
        let pid = a.pid
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.holdEnded(pid)
        }
        holdTimers[pid] = (a.since, task)
    }

    private func holdEnded(_ pid: Int32) {
        holdTimers[pid] = nil
        bump()
    }

    // MARK: Changes

    private func bump() { revision &+= 1 }

    private func post(_ message: NotchDockMessage) {
        postedCount += 1
        channel.post(message)
    }

    // MARK: Tests

    /// Waits for pending trust checks (the in-memory bus delivers synchronously; verification is async).
    public func waitForVerifications() async {
        while let task = verifying.values.first {
            await task.value
            await Task.yield()
        }
    }
}
