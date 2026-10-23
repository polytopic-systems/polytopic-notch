import Darwin
import Dispatch

/// Tells the dock when a peer's process exits, so its announcement, trust verdict and hold timer are dropped.
/// (`NSWorkspace` terminate notifications don't fire for agent apps, which most notch apps are.)
@MainActor
public protocol NotchDockProcessWatching: AnyObject {
    func watch(pid: Int32, onExit: @escaping @MainActor () -> Void)
    func unwatch(pid: Int32)
}

/// One kqueue process source per peer (`DispatchSource.makeProcessSource(.exit)`): no polling, no timers. An exit is
/// seen within ~13 ms.
@MainActor
public final class NotchDockProcessWatcher: NotchDockProcessWatching {
    private var sources: [Int32: DispatchSourceProcess] = [:]

    public init() {}

    public func watch(pid: Int32, onExit: @escaping @MainActor () -> Void) {
        guard sources[pid] == nil else { return }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.unwatch(pid: pid)
                onExit()
            }
        }
        sources[pid] = source
        source.activate()
        // Already gone before the source was armed: report it now.
        if kill(pid, 0) != 0, errno == ESRCH {
            unwatch(pid: pid)
            onExit()
        }
    }

    public func unwatch(pid: Int32) {
        sources.removeValue(forKey: pid)?.cancel()
    }

    public var watchedCount: Int { sources.count }
}

/// Exits are simulated: tests.
@MainActor
public final class ManualNotchDockProcessWatcher: NotchDockProcessWatching {
    private var handlers: [Int32: @MainActor () -> Void] = [:]

    public init() {}

    public var watched: Set<Int32> { Set(handlers.keys) }

    public func watch(pid: Int32, onExit: @escaping @MainActor () -> Void) { handlers[pid] = onExit }

    public func unwatch(pid: Int32) { handlers[pid] = nil }

    public func simulateExit(_ pid: Int32) { handlers.removeValue(forKey: pid)?() }
}
