/// How the pill behaves when another app is also using the notch. Raw values are stored in the apps' preferences.
public enum NotchSharing: String, Codable, CaseIterable, Sendable {
    /// Step below the notch only while a neighbor is detected.
    case automatic
    case always
    case never

    public func shares(neighborPresent: Bool) -> Bool {
        switch self {
        case .automatic: neighborPresent
        case .always: true
        case .never: false
        }
    }
}
