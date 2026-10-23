import Observation

/// An app the user told the pill not to make room for (detected at the notch by mistake).
public struct NotchIgnoredApp: Codable, Hashable, Sendable, Identifiable {
    public var bundleID: String
    public var name: String
    public var id: String { bundleID }

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// The notch settings every app has, as one value. Each app keeps storing them in its own preferences under its
/// own field names (one app's `notchCaptionShape` can be another's `notchPillShape`), and bridges them with
/// `NotchSettingsStore`, so no app's stored preferences change shape. The enums' raw values are what the apps
/// already store: never rename them.
public struct NotchSettings: Equatable, Sendable {
    /// Show the pill at the notch at all.
    public var isShown = true
    public var display: NotchDisplay = .builtIn
    /// Whether to step below the notch when another app (Bartender's Top Shelf, Boring Notch…) is using it.
    public var sharing: NotchSharing = .automatic
    /// Apps detected at the notch that the user said not to make room for (false positives).
    public var ignoredApps: [NotchIgnoredApp] = []
    /// When the notch is ours: grow across the menu bar, or stay notch-wide inside it.
    public var pillShape: NotchPillShape = .grow
    /// When the notch is ours and quiet: a dot and meter beside the notch, or a slim line under it.
    public var indicator: NotchIndicatorPosition = .besideNotch
    /// Text size of the app's own text in the pill (headline, captions); the preview reads it.
    public var fontSize: Double = 15

    public init(isShown: Bool = true, display: NotchDisplay = .builtIn, sharing: NotchSharing = .automatic,
                ignoredApps: [NotchIgnoredApp] = [], pillShape: NotchPillShape = .grow,
                indicator: NotchIndicatorPosition = .besideNotch, fontSize: Double = 15) {
        self.isShown = isShown
        self.display = display
        self.sharing = sharing
        self.ignoredApps = ignoredApps
        self.pillShape = pillShape
        self.indicator = indicator
        self.fontSize = fontSize
    }
}

/// The bridge to an app's own settings object. Conform the app's observable settings class in an extension:
///
///     extension AppSettings: NotchSettingsStore {
///         var notch: NotchSettings {
///             get { NotchSettings(isShown: showNotch, …, pillShape: notchCaptionShape, …) }
///             set { showNotch = newValue.isShown; …; notchCaptionShape = newValue.pillShape; … }
///         }
///     }
///
/// Reading `notch` must read the app's observable properties, so observation (the controller's settings watch,
/// SwiftUI) follows changes; writing it should write only the fields that changed when that matters to the app.
@MainActor
public protocol NotchSettingsStore: AnyObject {
    var notch: NotchSettings { get set }
}

/// Settings kept in memory: tests, previews, and apps that don't persist them.
@MainActor
@Observable
public final class InMemoryNotchSettings: NotchSettingsStore {
    public var notch: NotchSettings

    public init(_ notch: NotchSettings = NotchSettings()) {
        self.notch = notch
    }
}
