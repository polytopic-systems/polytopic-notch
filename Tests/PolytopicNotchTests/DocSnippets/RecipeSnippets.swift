// The code in Recipes.md, verbatim, so it compiles. Recipes that extend `MyNotch` build on GettingStartedSnippets.swift.
// Statement blocks sit inside functions that are never called.

import AppKit
import PolytopicNotch
import SwiftUI

// MARK: A quiet indicator

extension MyNotch {
    func showQuiet(level: Double) {
        content.status = .quiet                       // meter and dot beside the notch
        content.level = level                         // 0...1
        content.dot = NotchDot(color: .green, pulsing: false)
        content.want = .quiet
    }

    func showBusy() {
        content.busy = true                           // loading bars: something the user waits for
    }

    func turnOff() {
        content.status = .off                         // just the notch
    }
}

@MainActor
private func recipeIndicatorUnderNotch(_ settings: InMemoryNotchSettings) {
    settings.notch.indicator = .underNotch            // a slim line under the notch instead
}

// MARK: Post a notice

extension MyNotch {
    func post(_ headline: String) {
        content.showing = NotchBody(height: 34) { Headline(text: headline) }
        content.status = .showing
        content.want = .notice
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.content.status = .quiet
            self?.content.want = .quiet
        }
    }
}

struct Headline: View {
    let text: String
    @Environment(NotchViewModel.self) private var pill

    var body: some View {
        Text(text)
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .frame(width: pill.bodyTextWidth)         // steady while the pill animates
    }
}

// MARK: A hover panel

extension MyNotch {
    func setUpHoverPanel() {
        content.expanded = NotchBody(height: 140) { HoverPanel() }
    }
}

struct HoverPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Today").font(.headline)
            Text("3 events, nothing waiting").foregroundStyle(.secondary)
            Button("Open My App") { NSApp.activate() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
    }
}

// MARK: A live list

struct LogEvent: Identifiable, Equatable {
    let id: Int
    let text: String
}

@MainActor
@Observable
final class EventLog {
    let feed = NotchLiveFeed<LogEvent>(edge: .top)    // newest first
    private var events: [LogEvent] = []
    private var nextID = 0

    func add(_ text: String) {
        events.insert(LogEvent(id: nextID, text: text), at: 0)
        nextID += 1
        events = Array(events.prefix(50))
        feed.publish(events)                          // the whole list, in display order
    }
}

struct EventList: View {
    let log: EventLog

    var body: some View {
        NotchLiveList(log.feed, spacing: 2) { event in
            HStack {
                Text(event.text).lineLimit(1)
                Spacer()
                Button("Dismiss") {}
            }
            .notchLiveAction()                        // pointing at a row with buttons holds the list still
        }
        .frame(height: 150)
        .padding(.horizontal, 16)
    }
}

// MARK: A menu in the pill

struct PanelMenu: View {
    var body: some View {
        NotchMenuButton(menu: makeMenu) { isOpen in
            Image(systemName: "ellipsis.circle")
                .padding(4)
                .background(Circle().fill(.primary.opacity(isOpen ? 0.25 : 0.1)))
        }
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Pause") { print("paused") })
        menu.addItem(ClosureMenuItem("Clear the List") { print("cleared") })
        return menu
    }
}

// MARK: A question

extension MyNotch {
    func askAboutNotices() {
        content.prompt = NotchBody(height: 86) {
            NoticesQuestion { [weak self] keep in
                self?.content.prompt = nil            // answered: the question closes, in the pill or its window
                print(keep ? "keep" : "turn off")
            }
        }
    }
}

struct NoticesQuestion: View {
    let answer: @MainActor (Bool) -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text("Keep showing notices?").font(.callout.weight(.semibold))
            HStack {
                Button("Turn Off") { answer(false) }
                Button("Keep On") { answer(true) }.buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 16)
    }
}

// MARK: Tabs

struct Message: Identifiable, Equatable {
    let id: Int
    let text: String
}

@MainActor
@Observable
final class Inbox {
    enum Tab: CaseIterable {
        case unread, all
        var title: String { self == .unread ? "Unread" : "All" }
    }

    let feed = NotchLiveFeed<Message>(edge: .top)
    var messages: [Message] = []
    var unread: Set<Int> = []
    var tab: Tab = .unread {
        didSet { if tab != oldValue { feed.reset(); publish() } }   // a new tab starts at its newest row
    }

    func publish() {
        feed.publish(tab == .unread ? messages.filter { unread.contains($0.id) } : messages)
    }
}

struct InboxPanel: View {
    @Bindable var inbox: Inbox                        // the selection lives in your model, not in @State

    var body: some View {
        VStack(spacing: 8) {
            NotchTabBar(Inbox.Tab.allCases, selection: $inbox.tab) { $0.title }
            NotchLiveList(inbox.feed) { Text($0.text).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(height: 150)                   // fixed, so the pill keeps its size from tab to tab
        }
        .padding(16)
    }
}

// MARK: Opt into the dock

@MainActor
final class DockedNotch {
    let content = NotchContent()
    let settings = InMemoryNotchSettings()
    let neighbors = NotchNeighborMonitor()
    let dock = NotchDock(symbol: "waveform")          // your bundle ID; docks with apps signed for shipping
    lazy var controller = NotchPanelController(content: content, settings: settings, neighbors: neighbors, dock: dock)

    func sessionStarted() { content.want = .live }    // none < quiet < notice < live; a question is urgent by itself
    func sessionEnded() { content.want = .quiet }
}

// MARK: The block list

@MainActor
private func recipeBlockList(_ dock: NotchDock) {
    dock.setBlocked("com.example.NoisyApp", true)     // every docked app drops it; false lets it back in
    let blocked = dock.blocked                        // the bundle IDs kept out
    print(blocked)
}

// MARK: A theme

let brandTheme = NotchTheme(
    accent: { Color(red: 0.55, green: 0.36, blue: 0.96) },
    accentText: { scheme in scheme == .dark ? Color(red: 0.72, green: 0.6, blue: 1) : Color(red: 0.42, green: 0.24, blue: 0.82) },
    attention: .orange
)

@MainActor
private func recipeTheme(_ content: NotchContent, _ settings: InMemoryNotchSettings, _ neighbors: NotchNeighborMonitor) {
    let controller = NotchPanelController(content: content, settings: settings, neighbors: neighbors, theme: brandTheme)
    _ = controller
}

// MARK: Logging and diagnostics

@MainActor
private func recipeLogging(_ content: NotchContent, _ settings: InMemoryNotchSettings) {
    let log = NotchLog.unified(subsystem: "com.example.MyApp")       // or NotchLog { level, message in … }, or .silent
    let diagnostics = NotchDiagnostics(log: log)                      // placement and neighbors, for a support report
    let neighbors = NotchNeighborMonitor(log: log)
    let dock = NotchDock(symbol: "waveform", log: log)
    let controller = NotchPanelController(content: content, settings: settings, neighbors: neighbors,
                                          diagnostics: diagnostics, log: log, dock: dock)
    _ = controller
}

// MARK: Settings rows

struct NotchSettingsPage: View {
    let settings: any NotchSettingsStore
    let neighbors: NotchNeighborMonitor
    let dock: NotchDock

    var body: some View {
        Form {
            Section("The pill") {
                NotchDisplayPicker(settings: settings)
                NotchSharingPicker(settings: settings)
                NotchOwnLookRows(settings: settings, monitor: neighbors)
            }
            Section("Apps beside the notch") {
                NotchNeighborRows(settings: settings, monitor: neighbors)
            }
            Section("Sharing the notch with your other apps") {
                NotchDockSettingsRows(dock: dock)
            }
        }
        .formStyle(.grouped)
        .notchNeighborsAttentive(neighbors, reason: "settings")     // looks for neighbors closely while it shows
    }
}

@MainActor
@Observable
final class AppPreferences: NotchSettingsStore {
    var showNotch = true                              // stored under your own names, in your own preferences
    var notchSharing = NotchSharing.automatic
    var notchShape = NotchPillShape.grow

    var notch: NotchSettings {
        get { NotchSettings(isShown: showNotch, sharing: notchSharing, pillShape: notchShape) }
        set {
            showNotch = newValue.isShown
            notchSharing = newValue.sharing
            notchShape = newValue.pillShape
        }
    }
}
