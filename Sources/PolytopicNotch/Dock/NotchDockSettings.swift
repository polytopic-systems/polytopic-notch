import Foundation

/// Where the shared dock settings live: `UserDefaults` in the apps, `InMemoryNotchDockSettingsStorage` in tests (so
/// tests never write preference files).
@MainActor
public protocol NotchDockSettingsStorage: AnyObject {
    func string(forKey key: String) -> String?
    func double(forKey key: String) -> Double
    func bool(forKey key: String) -> Bool
    func stringArray(forKey key: String) -> [String]?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: NotchDockSettingsStorage {}

@MainActor
public final class InMemoryNotchDockSettingsStorage: NotchDockSettingsStorage {
    private var values: [String: Any] = [:]
    public init() {}
    public func string(forKey key: String) -> String? { values[key] as? String }
    public func double(forKey key: String) -> Double { values[key] as? Double ?? 0 }
    public func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    public func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    public func set(_ value: Any?, forKey key: String) { values[key] = value }
}

/// The dock settings every docked app shares, in `UserDefaults(suiteName: "systems.polytopic.notch")`
/// (`~/Library/Preferences/systems.polytopic.notch.plist` for apps that aren't sandboxed; a sandboxed app's suite is
/// its own copy inside its container). Every app keeps them in step over the dock's messages: each write stamps the
/// settings (`updatedAt`, `writer`), `NotchDock` posts the snapshot in a `style` message, and every app adopts a
/// snapshot newer than its own (`adopt`). Joining the dock (`register`) is not a write, so a fresh app never resets
/// everyone to its defaults.
@MainActor
public final class NotchDockSettings {
    public static let suiteName = "systems.polytopic.notch"

    /// Keys in the suite. Never rename them.
    public enum Key {
        public static let style = "notch.sharingStyle"
        public static let holdSeconds = "notch.urgentHoldSeconds"
        public static let holdUntilAnswered = "notch.urgentHoldUntilAnswered"
        public static let order = "notch.appOrder"
        public static let blocked = "notch.blockedApps"
        public static let updatedAt = "notch.updatedAt"
        public static let writer = "notch.writer"
    }

    private let defaults: NotchDockSettingsStorage
    private let now: @MainActor () -> Date
    /// Who stamps a write (the app's bundle ID); ties between equal stamps go to the greater writer.
    public var writer: String

    /// `storage: nil` (or an unavailable suite) falls back to the app's standard defaults.
    public init(storage: NotchDockSettingsStorage? = UserDefaults(suiteName: NotchDockSettings.suiteName),
                writer: String = Bundle.main.bundleIdentifier ?? "unknown",
                now: @escaping @MainActor () -> Date = { Date() }) {
        defaults = storage ?? UserDefaults.standard
        self.writer = writer
        self.now = now
    }

    /// When the settings were last written by a user's change anywhere (`.distantPast`: never).
    public var updatedAt: Date {
        let t = defaults.double(forKey: Key.updatedAt)
        return t > 0 ? Date(timeIntervalSinceReferenceDate: t) : .distantPast
    }

    private func stamp() {
        defaults.set(now().timeIntervalSinceReferenceDate, forKey: Key.updatedAt)
        defaults.set(writer, forKey: Key.writer)
    }

    /// Everything the apps share, with its stamp.
    public var snapshot: NotchDockSharedSettings {
        NotchDockSharedSettings(style: defaults.string(forKey: Key.style) ?? NotchSharingStyle.priority.rawValue,
                                holdSeconds: urgentHoldSeconds, holdUntilAnswered: defaults.bool(forKey: Key.holdUntilAnswered),
                                order: order, blocked: blocked.sorted(), updatedAt: updatedAt,
                                writer: defaults.string(forKey: Key.writer) ?? "")
    }

    public enum Adoption: Equatable, Sendable {
        /// The incoming snapshot was newer and is now these settings.
        case adopted
        /// Both are the same snapshot.
        case same
        /// These settings are newer: the sender should hear them.
        case oursIsNewer
    }

    /// Takes another app's snapshot if it is newer than these settings. The snapshot is sanitized first, with this
    /// store's clock (`NotchDockSharedSettings.sanitized`), and compared by the same clock, so two apps never both find
    /// theirs newer. This app stays in the order if it was.
    @discardableResult
    public func adopt(_ incoming: NotchDockSharedSettings) -> Adoption {
        let s = incoming.sanitized(now: now())
        let mine = snapshot
        if mine.isNewer(than: s) { return .oursIsNewer }
        guard s.isNewer(than: mine) else { return .same }
        let myOrder = order
        defaults.set(s.style, forKey: Key.style)
        defaults.set(s.holdSeconds, forKey: Key.holdSeconds)
        defaults.set(s.holdUntilAnswered, forKey: Key.holdUntilAnswered)
        var merged = s.order
        for id in myOrder where !merged.contains(id) { merged.append(id) }
        defaults.set(merged, forKey: Key.order)
        defaults.set(s.blocked, forKey: Key.blocked)
        defaults.set(s.updatedAt.timeIntervalSinceReferenceDate, forKey: Key.updatedAt)
        defaults.set(s.writer, forKey: Key.writer)
        return .adopted
    }

    /// The stored style; a value this app doesn't know reads as Priority (and is left as it is in storage).
    public var style: NotchSharingStyle { NotchSharingStyle(stored: defaults.string(forKey: Key.style)) }

    public func setStyle(_ style: NotchSharingStyle) {
        defaults.set(style.rawValue, forKey: Key.style)
        stamp()
    }

    public var urgentHold: NotchUrgentHold {
        if defaults.bool(forKey: Key.holdUntilAnswered) { return .untilAnswered }
        let seconds = defaults.double(forKey: Key.holdSeconds)
        return seconds > 0 ? .seconds(seconds) : .standard
    }

    /// The seconds last chosen, kept while "until answered" is on (30 by default).
    public var urgentHoldSeconds: Double {
        let seconds = defaults.double(forKey: Key.holdSeconds)
        return seconds > 0 ? seconds : 30
    }

    public func setUrgentHold(_ hold: NotchUrgentHold) {
        switch hold {
        case .untilAnswered:
            defaults.set(true, forKey: Key.holdUntilAnswered)
        case .seconds(let s):
            defaults.set(false, forKey: Key.holdUntilAnswered)
            defaults.set(max(1, s), forKey: Key.holdSeconds)
        }
        stamp()
    }

    /// App IDs left→right (Split), top→bottom (Merged), tie-break rank (Priority). Apps not listed come after, by app
    /// ID. Includes apps that aren't running, so their place is kept.
    public var order: [String] { defaults.stringArray(forKey: Key.order) ?? [] }

    public func setOrder(_ order: [String]) {
        writeOrder(order)
        stamp()
    }

    private func writeOrder(_ order: [String]) {
        var seen = Set<String>()
        defaults.set(order.filter { seen.insert($0).inserted }, forKey: Key.order)
    }

    /// App IDs the user doesn't want in the dock. Every app ignores them (they get the make-room behaviour instead).
    public var blocked: Set<String> { Set(defaults.stringArray(forKey: Key.blocked) ?? []) }

    public func setBlocked(_ blocked: Set<String>) {
        defaults.set(blocked.sorted(), forKey: Key.blocked)
        stamp()
    }

    /// Adds an app at the end the first time it docks, so the Settings list shows it. Not a write: no stamp.
    public func register(appID: String) {
        let current = order
        if !current.contains(appID) { writeOrder(current + [appID]) }
    }
}

/// The settings as they travel between apps in a `style` message. Strings from another process are untrusted:
/// `sanitized` caps the lists and IDs and pulls a stamp from the future back to now, so one app can't make its
/// settings win forever.
public struct NotchDockSharedSettings: Codable, Sendable, Equatable {
    public var style: String
    public var holdSeconds: Double
    public var holdUntilAnswered: Bool
    public var order: [String]
    public var blocked: [String]
    public var updatedAt: Date
    public var writer: String

    public static let maxApps = 64
    public static let maxIDLength = 255

    public init(style: String, holdSeconds: Double, holdUntilAnswered: Bool, order: [String], blocked: [String],
                updatedAt: Date, writer: String) {
        self.style = style
        self.holdSeconds = holdSeconds
        self.holdUntilAnswered = holdUntilAnswered
        self.order = order
        self.blocked = blocked
        self.updatedAt = updatedAt
        self.writer = writer
    }

    /// Newest stamp wins; equal stamps go to the greater writer, so every app picks the same snapshot.
    public func isNewer(than other: NotchDockSharedSettings) -> Bool {
        (updatedAt, writer) > (other.updatedAt, other.writer)
    }

    public func sanitized(now: Date) -> NotchDockSharedSettings {
        func ids(_ list: [String]) -> [String] {
            var seen = Set<String>()
            return list.filter { !$0.isEmpty && $0.count <= Self.maxIDLength && seen.insert($0).inserted }
                .prefix(Self.maxApps).map { $0 }
        }
        var s = self
        s.style = style.count <= 32 ? style : NotchSharingStyle.priority.rawValue
        s.holdSeconds = holdSeconds.isFinite ? min(max(holdSeconds, 1), 3600) : 30
        s.order = ids(order)
        s.blocked = ids(blocked)
        s.writer = String(writer.prefix(Self.maxIDLength))
        if updatedAt > now.addingTimeInterval(60) { s.updatedAt = now }
        return s
    }
}
