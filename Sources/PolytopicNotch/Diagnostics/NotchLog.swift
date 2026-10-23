import OSLog

/// Where the notch code logs. Each app passes its own (its developer console's log, category "notch"), so the
/// package holds no logger of its own and nothing global to configure.
public struct NotchLog: Sendable {
    public enum Level: String, Sendable {
        case debug, info, notice
    }

    public var write: @Sendable (Level, String) -> Void

    public init(_ write: @escaping @Sendable (Level, String) -> Void) {
        self.write = write
    }

    public func debug(_ message: String) { write(.debug, message) }
    public func info(_ message: String) { write(.info, message) }
    public func notice(_ message: String) { write(.notice, message) }

    /// Drops everything (tests, previews).
    public static let silent = NotchLog { _, _ in }

    /// Straight to the unified log, for an app without a developer console.
    public static func unified(subsystem: String, category: String = "notch") -> NotchLog {
        let logger = Logger(subsystem: subsystem, category: category)
        return NotchLog { level, message in
            switch level {
            case .debug: logger.debug("\(message, privacy: .public)")
            case .info: logger.info("\(message, privacy: .public)")
            case .notice: logger.notice("\(message, privacy: .public)")
            }
        }
    }
}
