import Foundation

/// One message between docked apps. Every message names its sender's pid; trust is decided on that pid.
public enum NotchDockMessage: Sendable, Equatable {
    /// Sent when a dock starts (and on wake or a screen change). Peers answer with `announce`.
    case hello(NotchDockAnnouncement)
    /// Sent only when a field of the sender's announcement changes, and in reply to `hello`.
    case announce(NotchDockAnnouncement)
    /// The sender's shared settings (`nil` from an app that only asks to re-read local storage): adopt them if newer.
    case style(pid: Int32, settings: NotchDockSharedSettings?)
    /// The sender stopped its dock (it may keep running). Quitting is seen by the process watcher.
    case bye(pid: Int32, instance: String)

    public var senderPID: Int32 {
        switch self {
        case .hello(let a), .announce(let a): a.pid
        case .style(let pid, _), .bye(let pid, _): pid
        }
    }

    public var kind: Kind {
        switch self {
        case .hello: .hello
        case .announce: .announce
        case .style: .style
        case .bye: .bye
        }
    }

    public enum Kind: String, Sendable, CaseIterable {
        case hello, announce, style, bye
    }
}

/// The wire format: notification name `<prefix>.<kind>`, and a JSON payload string as the notification's `object`
/// (never `userInfo`: the App Sandbox drops distributed notifications that carry one, so sandboxed apps could not
/// dock). The prefix carries the protocol major (`v2`), so apps on different majors don't see each other and each keeps
/// its solo behaviour. Dates are JSON numbers relative to the reference date (the default), so they round-trip
/// exactly and every app ranks the same values.
public enum NotchDockWire {
    public static let prefix = "systems.polytopic.notch.v2"

    public static func name(_ kind: NotchDockMessage.Kind, prefix: String = prefix) -> String { "\(prefix).\(kind.rawValue)" }

    private struct Small: Codable { var pid: Int32; var instance: String?; var settings: NotchDockSharedSettings? }

    public static func encode(_ message: NotchDockMessage) -> String {
        let encoder = JSONEncoder()
        let data: Data?
        switch message {
        case .hello(let a), .announce(let a): data = try? encoder.encode(a)
        case .style(let pid, let settings): data = try? encoder.encode(Small(pid: pid, instance: nil, settings: settings))
        case .bye(let pid, let instance): data = try? encoder.encode(Small(pid: pid, instance: instance, settings: nil))
        }
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    public static func decode(kind: NotchDockMessage.Kind, payload: String) -> NotchDockMessage? {
        let decoder = JSONDecoder()
        let data = Data(payload.utf8)
        switch kind {
        case .hello: return (try? decoder.decode(NotchDockAnnouncement.self, from: data)).map(NotchDockMessage.hello)
        case .announce: return (try? decoder.decode(NotchDockAnnouncement.self, from: data)).map(NotchDockMessage.announce)
        case .style: return (try? decoder.decode(Small.self, from: data)).map { .style(pid: $0.pid, settings: $0.settings) }
        case .bye: return (try? decoder.decode(Small.self, from: data)).map { .bye(pid: $0.pid, instance: $0.instance ?? "") }
        }
    }

    public static func decode(name: String, payload: String, prefix: String = prefix) -> NotchDockMessage? {
        guard name.hasPrefix(prefix + "."),
              let kind = NotchDockMessage.Kind(rawValue: String(name.dropFirst(prefix.count + 1))) else { return nil }
        return decode(kind: kind, payload: payload)
    }
}
