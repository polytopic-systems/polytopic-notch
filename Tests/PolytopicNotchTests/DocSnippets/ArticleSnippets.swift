// The code in YourOwnPanel.md, LiveLists.md, TheDock.md and Testing.md, verbatim, so it compiles. Nothing is started.

import AppKit
import PolytopicNotch
import SwiftUI
import Testing

// MARK: Your own panel

struct FeedItem: Identifiable, Equatable {
    let id: Int
    let text: String
}

struct FeedRow: View {
    let item: FeedItem
    var body: some View { Text(item.text).lineLimit(1) }
}

@MainActor
@Observable
final class Monitor {
    enum Tab: CaseIterable {
        case events, notices
        var title: String { self == .events ? "Events" : "Notices" }
    }

    let feed = NotchLiveFeed<FeedItem>(edge: .top)
    var tab: Tab = .events {
        didSet { if tab != oldValue { feed.reset() } }
    }

    func menu() -> NSMenu { NSMenu() }
}

@MainActor
private func panelSample(_ content: NotchContent, _ model: Monitor) {
content.expanded = NotchBody(height: 220) { MonitorPanel(model: model) }
}

struct MonitorPanel: View {
    @Bindable var model: Monitor        // your own model: the panel is rebuilt on every open

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                NotchTabBar(Monitor.Tab.allCases, selection: $model.tab) { $0.title }
                NotchMenuButton(menu: model.menu) { _ in Image(systemName: "ellipsis.circle") }
            }
            NotchLiveList(model.feed) { FeedRow(item: $0).notchLiveAction() }
        }
        .padding(16)
    }
}

@MainActor
private func sizeSamples(_ content: NotchContent, _ captionLines: @escaping @MainActor () -> Int) {
    content.expanded = NotchBody(width: 440, height: 200) { HoverPanel() }
    content.showing = NotchBody(height: { placement in placement == .menuBar ? 40 : CGFloat(captionLines()) * 20 + 20 }) {
        Text("Captions")
    }
}

struct ConnectionQuestion: View {
    @Environment(NotchViewModel.self) private var pill: NotchViewModel?    // nil in the floating window

    var body: some View {
        Text("Allow this connection?")
            .frame(width: pill?.bodyTextWidth ?? 300)
    }
}

// MARK: Live lists

struct Segment: Identifiable, Equatable {
    let id: Int
    let text: String
}

struct TranscriptView: View {
    let feed: NotchLiveFeed<Segment>                  // NotchLiveFeed(edge: .bottom): newest last

    var body: some View {
        NotchLiveList(feed, spacing: 4, showsIndicators: true) { segment in
            Text(segment.text)                        // not marked: pointing at text doesn't hold the list
        }
    }
}

@MainActor
func showResult(in feed: NotchLiveFeed<LogEvent>) async {
    feed.hold(.app("result"))                         // a row shows the result of a click: don't move it
    try? await Task.sleep(for: .seconds(3))
    feed.release(.app("result"))
}

@MainActor
private func liveListTiming(_ feed: NotchLiveFeed<LogEvent>) {
    feed.timing = .init(actionGrace: .seconds(1), readingIdle: .seconds(8))
}

// MARK: The dock

@MainActor
private func ownTeamDock() -> NotchDock {
    var options = DistributedNotchDockChannel.Options()
    options.prefix = "com.example.dock"               // your own channel: the shared dock never sees you
    let dock = NotchDock(symbol: "waveform",
                         channel: DistributedNotchDockChannel(options: options),
                         trust: CodeSignatureTrust(teamID: "ABCDE12345", bundlePrefix: "com.example."),
                         settings: NotchDockSettings(storage: UserDefaults(suiteName: "com.example.dock")))
    return dock
}

// MARK: Testing

@MainActor
func makeTestDock(appID: String = "com.example.Test", bus: InMemoryNotchDockBus = InMemoryNotchDockBus()) -> NotchDock {
    NotchDock(appID: appID, symbol: "circle",
              channel: bus.makeChannel(),                                  // never the real channel
              trust: NotchDockStaticTrust(trusted: nil),                   // trusts everyone on the bus
              settings: NotchDockSettings(storage: InMemoryNotchDockSettingsStorage()),   // never the shared suite
              processes: ManualNotchDockProcessWatcher())
}

@Suite("Doc snippets: testing")
@MainActor
struct DocSnippetTestingSamples {
    @MainActor @Test func aNoticeShowsThePill() {
        let content = NotchContent()
        let pill = NotchViewModel(content: content, settings: InMemoryNotchSettings(), geometry: .fallback)
        content.showing = NotchBody(height: 34) { Text("Hello") }
        content.status = .showing
        #expect(pill.mode == .showing)
        #expect(pill.size(for: .showing).height > 34)
    }

    @Test func aTestDockStaysInMemory() {
        let dock = makeTestDock()
        #expect(!dock.isRunning)
        _ = ownTeamDock
        _ = sizeSamples
        _ = panelSample
        _ = liveListTiming
    }
}
