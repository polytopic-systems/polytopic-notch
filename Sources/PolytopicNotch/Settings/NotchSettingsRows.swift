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
        Picker("Display", selection: settings.binding(\.display)) {
            Text("Built-in display").tag(NotchDisplay.builtIn)
            Text("Display I'm working on").tag(NotchDisplay.active)
        }
    }
}

/// "Make room for other notch apps": Automatically, Always or Never.
public struct NotchSharingPicker: View {
    var settings: any NotchSettingsStore
    var caption: String

    /// The caption says what moves ("captions hang just below it", "the pill hangs just below it").
    public init(settings: any NotchSettingsStore,
                caption: String = "When another app is using the notch, like Boring Notch, Atoll or Bartender's Top Shelf, the pill hangs just below it. It also steps under a menu bar manager's bar of hidden items while that is open. Hold Option on the notch to leave it to the other app.") {
        self.settings = settings
        self.caption = caption
    }

    public var body: some View {
        Picker(selection: settings.binding(\.sharing)) {
            Text("Automatically").tag(NotchSharing.automatic)
            Text("Always").tag(NotchSharing.always)
            Text("Never").tag(NotchSharing.never)
        } label: {
            Text("Make room for other notch apps")
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
            Text("No other app is using the notch right now.")
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
                Toggle("Make room", isOn: Binding(get: { makingRoom }, set: { setMakingRoom($0, for: row) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .help(makingRoom ? "Turn off if \(row.name) isn't really using the notch" : "Make room for \(row.name) again")
            }
        }
    }

    private func title(_ row: Row, makingRoom: Bool) -> String {
        guard makingRoom else { return "Not making room for \(row.name)" }
        return settings.notch.sharing == .never ? "\(row.name) is using the notch too" : "Sharing the notch with \(row.name)"
    }

    static func subtitle(_ row: Row) -> String {
        guard row.running else { return "Not running" }
        if row.profileName == "Bartender" { return "Top Shelf is on" }
        return row.profileName != nil ? "Known notch app" : "Found by its window over the notch"
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
    public var shapeTitle = "Shape"
    public var shapeSharedCaption = "Not used while the notch is shared: the pill already hangs below it."
    public var shapeCaption = "Keeping the menu bar clear leaves menus and icons beside the notch uncovered."
    public var indicatorTitle = "Quiet indicator"
    public var indicatorSharedCaption = "Not used while the notch is shared: a slim line under the notch shows it's active."
    public var indicatorCaption = "While there's nothing to show: a dot and meter beside the notch, or a slim line under it."

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
                Text("Grow from the notch").tag(NotchPillShape.grow)
                Text("Keep the menu bar clear").tag(NotchPillShape.clearMenuBar)
            } label: {
                Text(text.shapeTitle)
                notchSettingsCaption(sharing ? text.shapeSharedCaption : text.shapeCaption)
            }
            Picker(selection: settings.binding(\.indicator)) {
                Text("Beside the notch").tag(NotchIndicatorPosition.besideNotch)
                Text("Under the notch").tag(NotchIndicatorPosition.underNotch)
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
                        NotchLevelBars(level: 0.6, color: .white, barCount: 4, maxHeight: 9)
                        Spacer()
                        Circle().fill(dotColor ?? theme.accentText(.dark)).frame(width: 6, height: 6)
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
