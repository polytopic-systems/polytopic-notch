import AppKit
import SwiftUI

// Rows for an app's Settings › Notch (or Captions) page. The app keeps its own page and Form; these go inside it.
// Wording that names what the app shows ("captions", "the pill") is a parameter.

extension NotchSettingsStore {
    /// A binding to one notch setting, for pickers and toggles.
    public func binding<Value>(_ keyPath: WritableKeyPath<NotchSettings, Value>) -> Binding<Value> {
        Binding(get: { self.notch[keyPath: keyPath] }, set: { self.notch[keyPath: keyPath] = $0 })
    }
}

/// The secondary line under a row's title, as both apps' Settings draw it.
func notchSettingsCaption(_ text: String) -> Text {
    Text(text).font(.callout).foregroundStyle(.secondary)
}

/// Built-in display or the display the user is working on.
public struct NotchDisplayPicker: View {
    var settings: any NotchSettingsStore

    public init(settings: any NotchSettingsStore) {
        self.settings = settings
    }

    public var body: some View {
        Picker(String(localized: "Display", bundle: .module, comment: "Settings picker: which display the pill is on"), selection: settings.binding(\.display)) {
            Text("Built-in display", bundle: .module).tag(NotchDisplay.builtIn)
            Text("Display I'm working on", bundle: .module, comment: "The display the user is working on now").tag(NotchDisplay.active)
        }
    }
}

/// "Make room for other notch apps": Automatically, Always or Never.
public struct NotchSharingPicker: View {
    var settings: any NotchSettingsStore
    var caption: String

    /// The default caption, in the app's language.
    @usableFromInline static var defaultCaption: String {
        String(localized: "When another app is using the notch, like Boring Notch, Atoll or Bartender's Top Shelf, the pill hangs just below it. It also steps under a menu bar manager's bar of hidden items while that is open. Hold Option on the notch to leave it to the other app.",
               bundle: .module)
    }

    /// The caption says what moves ("captions hang just below it", "the pill hangs just below it").
    public init(settings: any NotchSettingsStore, caption: String = NotchSharingPicker.defaultCaption) {
        self.settings = settings
        self.caption = caption
    }

    public var body: some View {
        Picker(selection: settings.binding(\.sharing)) {
            Text("Automatically", bundle: .module, comment: "Make room for other notch apps: automatically").tag(NotchSharing.automatic)
            Text("Always", bundle: .module, comment: "Make room for other notch apps: always").tag(NotchSharing.always)
            Text("Never", bundle: .module, comment: "Make room for other notch apps: never").tag(NotchSharing.never)
        } label: {
            Text("Make room for other notch apps", bundle: .module, comment: "Settings picker title")
            notchSettingsCaption(caption)
        }
    }
}

/// Who else is using the notch right now, with a switch to stop making room for an app that was
/// detected by mistake. The choice is kept across launches.
public struct NotchNeighborRows: View {
    var settings: any NotchSettingsStore
    var monitor: NotchNeighborMonitor

    public init(settings: any NotchSettingsStore, monitor: NotchNeighborMonitor) {
        self.settings = settings
        self.monitor = monitor
    }

    struct Row: Identifiable, Equatable {
        var bundleID: String
        var name: String
        var running: Bool
        var profileName: String?
        var id: String { bundleID }
    }

    /// Everything the monitor counts (ignored apps included), then ignored apps that aren't running.
    static func rows(detected: [NotchNeighborMonitor.Neighbor], ignored: [NotchIgnoredApp]) -> [Row] {
        var rows: [Row] = []
        for neighbor in detected where !rows.contains(where: { $0.bundleID == neighbor.bundleID }) {
            rows.append(Row(bundleID: neighbor.bundleID, name: neighbor.name, running: true, profileName: neighbor.profileName))
        }
        for app in ignored where !rows.contains(where: { $0.bundleID == app.bundleID }) {
            rows.append(Row(bundleID: app.bundleID, name: app.name, running: false, profileName: nil))
        }
        return rows
    }

    public var body: some View {
        let rows = Self.rows(detected: monitor.detected, ignored: settings.notch.ignoredApps)
        if rows.isEmpty {
            Text("No other app is using the notch right now.", bundle: .module)
                .font(.callout).foregroundStyle(.secondary)
        }
        ForEach(rows) { row in
            let makingRoom = !isIgnored(row.bundleID)
            HStack(spacing: 10) {
                NotchAppIcon(bundleID: row.bundleID, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title(row, makingRoom: makingRoom)).lineLimit(1)
                    Text(Self.subtitle(row)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Toggle(String(localized: "Make room", bundle: .module, comment: "Switch (label hidden): make room in the notch for this other app"), isOn: Binding(get: { makingRoom }, set: { setMakingRoom($0, for: row) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .help(makingRoom ? String(localized: "Turn off if \(row.name) isn't really using the notch", bundle: .module, comment: "Tooltip; the name is another app")
                                      : String(localized: "Make room for \(row.name) again", bundle: .module, comment: "Tooltip; the name is another app"))
            }
        }
    }

    private func title(_ row: Row, makingRoom: Bool) -> String {
        guard makingRoom else { return String(localized: "Not making room for \(row.name)", bundle: .module, comment: "The name is another app that uses the notch") }
        return settings.notch.sharing == .never
            ? String(localized: "\(row.name) is using the notch too", bundle: .module, comment: "The name is another app that uses the notch")
            : String(localized: "Sharing the notch with \(row.name)", bundle: .module, comment: "The name is another app that uses the notch")
    }

    static func subtitle(_ row: Row) -> String {
        guard row.running else { return String(localized: "Not running", bundle: .module, comment: "Status of an app in a list: it isn't open") }
        if row.profileName == "Bartender" { return String(localized: "Top Shelf is on", bundle: .module, comment: "Top Shelf is a Bartender feature; keep its name") }
        return row.profileName != nil
            ? String(localized: "Known notch app", bundle: .module, comment: "Another app this package knows uses the notch")
            : String(localized: "Found by its window over the notch", bundle: .module, comment: "How another notch app was detected")
    }

    private func isIgnored(_ bundleID: String) -> Bool {
        settings.notch.ignoredApps.contains { $0.bundleID == bundleID }
    }

    private func setMakingRoom(_ on: Bool, for row: Row) {
        if on {
            settings.notch.ignoredApps.removeAll { $0.bundleID == row.bundleID }
        } else if !isIgnored(row.bundleID) {
            settings.notch.ignoredApps.append(NotchIgnoredApp(bundleID: row.bundleID, name: row.name))
        }
    }
}

/// The wording of `NotchOwnLookRows`, so an app can say "Caption shape" and "Listening indicator".
public struct NotchOwnLookText: Sendable {
    public var shapeTitle = String(localized: "Shape", bundle: .module, comment: "Settings picker title: the pill's shape")
    public var shapeSharedCaption = String(localized: "Not used while the notch is shared: the pill already hangs below it.", bundle: .module)
    public var shapeCaption = String(localized: "Keeping the menu bar clear leaves menus and icons beside the notch uncovered.", bundle: .module)
    public var indicatorTitle = String(localized: "Quiet indicator", bundle: .module,
                                       comment: "Settings picker title: what the pill shows while there's nothing to show")
    public var indicatorSharedCaption = String(localized: "Not used while the notch is shared: a slim line under the notch shows it's active.", bundle: .module)
    public var indicatorCaption = String(localized: "While there's nothing to show: a dot and meter beside the notch, or a slim line under it.", bundle: .module)

    public init() {}

    public static let standard = NotchOwnLookText()
}

/// How the pill looks when the notch is ours. Dimmed while it's shared, since the pill then hangs
/// below the notch and the menu bar is clear anyway.
///
/// These are settings rather than automatic because on macOS 27 the menu bar is one Window Server window
/// with no per-item status windows, so the free space beside the notch can't be detected without
/// Accessibility or Screen Recording permission, which the apps don't ask for.
public struct NotchOwnLookRows: View {
    var settings: any NotchSettingsStore
    var monitor: NotchNeighborMonitor
    var text: NotchOwnLookText

    public init(settings: any NotchSettingsStore, monitor: NotchNeighborMonitor, text: NotchOwnLookText = .standard) {
        self.settings = settings
        self.monitor = monitor
        self.text = text
    }

    private var sharing: Bool { settings.notch.sharing.shares(neighborPresent: monitor.neighborPresent) }

    public var body: some View {
        let sharing = sharing
        Group {
            Picker(selection: settings.binding(\.pillShape)) {
                Text("Grow from the notch", bundle: .module, comment: "Pill shape option").tag(NotchPillShape.grow)
                Text("Keep the menu bar clear", bundle: .module, comment: "Pill shape option").tag(NotchPillShape.clearMenuBar)
            } label: {
                Text(text.shapeTitle)
                notchSettingsCaption(sharing ? text.shapeSharedCaption : text.shapeCaption)
            }
            Picker(selection: settings.binding(\.indicator)) {
                Text("Beside the notch", bundle: .module, comment: "Quiet indicator position option").tag(NotchIndicatorPosition.besideNotch)
                Text("Under the notch", bundle: .module, comment: "Quiet indicator position option").tag(NotchIndicatorPosition.underNotch)
            } label: {
                Text(text.indicatorTitle)
                notchSettingsCaption(sharing ? text.indicatorSharedCaption : text.indicatorCaption)
            }
        }
        .disabled(sharing)
    }
}

/// A miniature screen with the pill in the current shape, around the app's own sample (a headline, captions).
/// Static apart from what `content` does itself: nothing else animates while Settings is open.
public struct NotchPreview<Content: View>: View {
    var settings: any NotchSettingsStore
    var theme: NotchTheme
    var height: CGFloat
    var dotColor: Color?
    var animating: AnyHashable?
    var content: Content

    public static var textWidth: CGFloat { 330 }
    static var notchWidth: CGFloat { 64 }
    static var cornerRadius: CGFloat { 8 }

    /// `content` is laid out `textWidth` wide below the band. `dotColor` defaults to the theme's accent. The pill
    /// springs to its new size when the shape, the text size or `animating` (e.g. the app's caption lines) changes.
    public init(settings: any NotchSettingsStore, theme: NotchTheme = .standard, height: CGFloat = 130, dotColor: Color? = nil,
                animating: AnyHashable? = nil, @ViewBuilder content: () -> Content) {
        self.settings = settings
        self.theme = theme
        self.height = height
        self.dotColor = dotColor
        self.animating = animating
        self.content = content()
    }

    public var body: some View {
        let notch = settings.notch
        let clear = notch.pillShape == .clearMenuBar
        let theme = theme.lit(by: notch.lightColor)
        ZStack(alignment: .top) {
            LinearGradient(colors: theme.previewBackdrop(), startPoint: .topLeading, endPoint: .bottomTrailing)
            // Menu bar strip.
            Rectangle().fill(.black.opacity(0.18)).frame(height: 16)
            VStack(spacing: 0) {
                if clear {
                    // The menu bar stays clear: only the notch-wide neck and its shoulders up there.
                    Color.clear.frame(height: 16 + NotchOutline.shoulder)
                } else {
                    HStack {
                        NotchLevelBars(level: 0.6, color: theme.meter ?? .white, barCount: 4, maxHeight: 9)
                        Spacer()
                        Circle().fill(notch.lightColor?.color ?? dotColor ?? theme.accentText(.dark)).frame(width: 6, height: 6)
                    }
                    .frame(height: 16)
                    .padding(.horizontal, 14)
                }
                content
                    .frame(width: Self.textWidth, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
            .frame(width: Self.textWidth + 44)
            .background(NotchOutline(topRadius: clear ? 0 : 5, bottomRadius: 16,
                                     neckWidth: clear ? Self.notchWidth : Self.textWidth + 44, neckDepth: clear ? 16 : 0).fill(.black))
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: clear)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: animating)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: notch.fontSize)
        }
        .frame(height: height)
        // A miniature screen. The section's own padding is only ~10 pt, so a strictly concentric
        // corner would be nearly square; 8 pt keeps it reading as a display, like System Settings'
        // wallpaper and display thumbnails.
        .clipShape(.rect(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
        }
    }
}

/// An app's icon, looked up off the main thread (Launch Services can be slow for apps that aren't running).
public struct NotchAppIcon: View {
    var bundleID: String
    var size: CGFloat
    @State private var image: NSImage?

    public init(bundleID: String, size: CGFloat) {
        self.bundleID = bundleID
        self.size = size
    }

    public var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: size * 0.23, style: .continuous).fill(.quaternary)
            }
        }
        .frame(width: size, height: size)
        .task(id: bundleID) { image = await Self.load(bundleID)?.image }
    }

    private struct Box: @unchecked Sendable { let image: NSImage }

    private static func load(_ bundleID: String) async -> Box? {
        await Task.detached(priority: .utility) { () -> Box? in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
            return Box(image: NSWorkspace.shared.icon(forFile: url.path))
        }.value
    }
}

extension View {
    /// Keeps the neighbor watch close while this view is on screen (a Settings page that lists neighbors).
    public func notchNeighborsAttentive(_ monitor: NotchNeighborMonitor, reason: String) -> some View {
        onAppear { monitor.setAttentive(true, for: reason) }
            .onDisappear { monitor.setAttentive(false, for: reason) }
    }
}
