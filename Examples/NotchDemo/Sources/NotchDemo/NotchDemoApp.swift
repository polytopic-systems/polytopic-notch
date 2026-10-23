// NotchDemo: a small menu bar app that shows what PolytopicNotch does. A pill at the notch with a quiet indicator, a
// short notice, a live session with a scrolling event list on hover, tabs and a menu inside the pill, a question with
// answer buttons, and the dock's shared settings. Everything it shows is made up; it sends nothing anywhere.
//
//     swift run --scratch-path ~/Library/Caches/notch-demo-build NotchDemo
//
// To see two apps share the notch, run two signed copies with different bundle IDs: `./make-app.sh` (README).

import AppKit
import Observation
import PolytopicNotch
import SwiftUI

@main
struct NotchDemoApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    private var demo: Demo { delegate.demo }

    var body: some Scene {
        MenuBarExtra("Notch Demo", systemImage: demo.symbol) {
            Button("Post a Notice") { demo.postNotice("Something happened just now") }
            Button(demo.isLive ? "Stop the Live Session" : "Start a Live Session") { demo.toggleLive() }
            Button("Ask a Question") { demo.ask() }
            Divider()
            SettingsLink { Text("Settings…") }
            Button("Quit") { NSApp.terminate(nil) }
        }
        Settings {
            DemoSettings(demo: demo)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let demo = Demo()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu bar app: no Dock icon (an app bundle says so with LSUIElement instead).
        NSApp.setActivationPolicy(.accessory)
        // The pill starts once the app has launched, not in an initializer SwiftUI runs while it builds the scenes.
        demo.start()
    }
}

/// One event in the live list.
struct DemoEvent: Identifiable, Equatable {
    let id: Int
    let text: String
    let at: Date
}

/// The app's model: it owns the pill's content and the pieces of the package, and changes the content as things happen.
@MainActor
@Observable
final class Demo {
    let content = NotchContent()
    let settings = InMemoryNotchSettings()
    let feed = NotchLiveFeed<DemoEvent>(edge: .top)
    @ObservationIgnored let neighbors: NotchNeighborMonitor
    @ObservationIgnored let dock: NotchDock
    @ObservationIgnored let notch: NotchPanelController
    @ObservationIgnored let prompts: NotchPromptWindowController

    static let symbol = "sparkles"
    var symbol: String { Self.symbol }
    private(set) var isLive = false
    private(set) var notice = ""
    private(set) var answer: String?
    private var events: [DemoEvent] = []
    /// The notices posted so far, newest first: the panel's second tab.
    private var notices: [DemoEvent] = []

    /// The panel's tabs. The selection lives here, not in the panel's view: the panel is built again every time the
    /// pill opens.
    enum PanelTab: CaseIterable {
        case events, notices
        var title: String { self == .events ? "Events" : "Notices" }
    }

    var tab: PanelTab = .events {
        // A new tab starts at its newest row.
        didSet { if tab != oldValue { feed.reset(); publish() } }
    }
    @ObservationIgnored private var nextID = 1
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    init() {
        let log = NotchLog.unified(subsystem: Bundle.main.bundleIdentifier ?? "NotchDemo")
        neighbors = NotchNeighborMonitor(log: log)
        // A bare `swift run` binary has no bundle ID; name it so the dock's order and block list can tell copies apart.
        dock = NotchDock(appID: Bundle.main.bundleIdentifier ?? "com.example.NotchDemo", symbol: Self.symbol, log: log)
        notch = NotchPanelController(content: content, settings: settings, neighbors: neighbors, log: log, dock: dock)
        let notch = notch
        prompts = NotchPromptWindowController(content: content) { notch.pillShowsPrompt }

        content.symbol = Self.symbol
        content.title = "Notch Demo"
        content.status = .quiet
        content.want = .quiet
        content.showing = NotchBody(height: 34) { [unowned self] in NoticeView(demo: self) }
        content.expanded = NotchBody(height: 220) { [unowned self] in ExpandedView(demo: self) }
    }

    /// Shows the pill and floats questions it can't show. Called once the app has finished launching.
    func start() {
        notch.start()
        observe { [prompts] in prompts.update() }
    }

    // MARK: What happens

    func postNotice(_ text: String) {
        notice = text
        notices.insert(DemoEvent(id: nextID, text: text, at: Date()), at: 0)
        nextID += 1
        notices = Array(notices.prefix(50))
        if tab == .notices { publish() }
        content.status = .showing
        updateWant()
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            self.notice = ""
            self.content.status = self.isLive ? .showing : .quiet
            self.updateWant()
        }
    }

    func toggleLive() {
        isLive.toggle()
        liveTask?.cancel()
        if isLive {
            notice = "Live session running"
            content.status = .showing
            liveTask = Task { [weak self] in
                while !Task.isCancelled {
                    self?.addEvent()
                    try? await Task.sleep(for: .seconds(1.5))
                }
            }
        } else {
            notice = ""
            content.status = .quiet
            content.level = 0
        }
        updateWant()
    }

    func ask() {
        answer = nil
        content.prompt = NotchBody(height: 86) { [unowned self] in QuestionView(demo: self) }
        updateWant()
    }

    func answer(_ text: String) {
        answer = text
        content.prompt = nil
        postNotice("You answered: \(text)")
    }

    /// Empties the list on the tab that shows.
    func clearList() {
        switch tab {
        case .events: events = []
        case .notices: notices = []
        }
        publish()
    }

    private func publish() {
        feed.publish(tab == .events ? events : notices)
    }

    private func addEvent() {
        let samples = ["Fetched the weather", "Saved a draft", "Synced 3 items", "Checked for updates", "Indexed a folder"]
        events.insert(DemoEvent(id: nextID, text: samples[nextID % samples.count], at: Date()), at: 0)
        nextID += 1
        events = Array(events.prefix(50))
        if tab == .events { publish() }
        content.level = Double.random(in: 0.2...1)
    }

    /// What the dock is told: the dock shares the notch by how much each app wants it. A waiting question is
    /// announced as urgent by the package itself.
    private func updateWant() {
        content.want = isLive ? .live : notice.isEmpty ? .quiet : .notice
    }
}

/// Re-runs `apply` whenever an observable value it read changes.
@MainActor
func observe(_ apply: @escaping @MainActor () -> Void) {
    withObservationTracking(apply) {
        Task { @MainActor in observe(apply) }
    }
}

// MARK: Bodies

struct NoticeView: View {
    var demo: Demo
    @Environment(NotchViewModel.self) private var pill

    var body: some View {
        Text(demo.notice.isEmpty ? "Nothing new" : demo.notice)
            .font(.callout.weight(.medium))
            .foregroundStyle(.white)
            .lineLimit(1)
            .frame(width: pill.bodyTextWidth)
    }
}

struct ExpandedView: View {
    @Bindable var demo: Demo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                NotchTabBar(Demo.PanelTab.allCases, selection: $demo.tab) { $0.title }
                    .frame(width: 200)
                Spacer()
                if demo.isLive {
                    Label("Live", systemImage: "dot.radiowaves.left.and.right").font(.callout.weight(.medium))
                }
                NotchMenuButton(menu: menu) { isOpen in
                    Image(systemName: "ellipsis.circle")
                        .padding(4)
                        .background(Circle().fill(.white.opacity(isOpen ? 0.25 : 0.1)))
                }
            }
            NotchLiveList(demo.feed, spacing: 2) { event in
                EventRow(event: event)
                    .notchLiveAction()   // pointing at a row (and its button) holds the list still
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func menu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(demo.isLive ? "Stop the Live Session" : "Start a Live Session") { demo.toggleLive() })
        menu.addItem(ClosureMenuItem("Clear the List") { demo.clearList() })
        return menu
    }
}

struct EventRow: View {
    let event: DemoEvent

    var body: some View {
        HStack {
            Text(event.text).lineLimit(1)
            Spacer()
            Text(event.at, style: .time).foregroundStyle(.white.opacity(0.6))
        }
        .font(.callout)
        .padding(.vertical, 3)
    }
}

struct QuestionView: View {
    var demo: Demo

    var body: some View {
        VStack(spacing: 8) {
            Text("Keep the demo's notices on?").font(.callout.weight(.semibold))
            // No keyboard shortcut: a stray Return must never answer a question.
            HStack {
                Button("Turn Off") { demo.answer("Turn Off") }
                Button("Keep On") { demo.answer("Keep On") }.buttonStyle(.borderedProminent)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
    }
}

// MARK: Settings

struct DemoSettings: View {
    var demo: Demo

    var body: some View {
        Form {
            Section("The pill") {
                NotchDisplayPicker(settings: demo.settings)
                NotchSharingPicker(settings: demo.settings)
                NotchOwnLookRows(settings: demo.settings, monitor: demo.neighbors)
            }
            Section("Sharing the notch with other apps") {
                NotchDockSettingsRows(dock: demo.dock)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 560)
    }
}
