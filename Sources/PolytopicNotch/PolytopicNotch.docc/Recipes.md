# Recipes

Copy-paste code for the common tasks.

## Overview

Recipes that extend `MyNotch` build on the class in <doc:GettingStarted>. Every block here is compiled by the
package's tests, so it matches the API.

## A quiet indicator

```swift
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
```

The user can choose a slim line under the notch instead (Settings rows below), or you can set it:

```swift
settings.notch.indicator = .underNotch            // a slim line under the notch instead
```

## Post a notice

```swift
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
```

- `bodyTextWidth` stays fixed while the pill springs open, so the text doesn't reflow; docked, it's your part's width.
- A `showing` body takes no clicks: hovering it opens `expanded`.

## A hover panel

```swift
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
```

- Opens while the pointer is on the pill; clicks work. No keyboard focus, so no text fields.
- The view is rebuilt on every open: keep state in your model. More in <doc:YourOwnPanel>.

## A live list

```swift
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
```

It follows the newest row, and holds still while the pointer is on a marked row, a menu is open or the user scrolled
back; an "N new" capsule brings it back. Details: <doc:LiveLists>.

## A menu in the pill

```swift
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
```

Use `NotchMenuButton`, never a SwiftUI `Menu`: it holds the pill open while the menu shows. The menu is built on
each click, so it shows current state.

## A question with buttons

```swift
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
```

- The pill grows around the question where it hangs from a notch. Elsewhere (no notch, the pill off, another app
  has the notch) `MyNotch`'s `NotchPromptWindowController` shows it in a small floating window.
- No keyboard shortcuts on the buttons: a stray Return must never answer.
- The floating window has no `NotchViewModel` in the environment; read it as optional (<doc:YourOwnPanel>).

## Tabs

```swift
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
```

``NotchTabBar`` fills the width it's given and is 24 pt tall. For icons, use the label init:
`NotchTabBar(tabs, selection: $tab) { tab, isSelected in Image(systemName: tab.symbol) }`.

## Opt into the dock

```swift
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
```

- Other apps using this package share the notch with you in the style the user picks: Priority, Switcher, Split or
  Merged. Without a dock you're solo and make room for other notch apps.
- Keep `want` honest: it decides who gets the notch. Add `NotchDockSettingsRows(dock:)` to Settings (below).
- Only apps signed with Developer ID or for the Mac App Store dock; your Debug builds dock too. <doc:TheDock>.

## The block list

```swift
dock.setBlocked("com.example.NoisyApp", true)     // every docked app drops it; false lets it back in
let blocked = dock.blocked                        // the bundle IDs kept out
```

The user does the same with a right-click in `NotchDockAppList` (part of `NotchDockSettingsRows`).

## A theme

```swift
let brandTheme = NotchTheme(
    accent: { Color(red: 0.55, green: 0.36, blue: 0.96) },
    accentText: { scheme in scheme == .dark ? Color(red: 0.72, green: 0.6, blue: 1) : Color(red: 0.42, green: 0.24, blue: 0.82) },
    attention: .orange
)
```

```swift
let controller = NotchPanelController(content: content, settings: settings, neighbors: neighbors, theme: brandTheme)
```

- `accent` fills large marks; `accentText` is for text and thin marks, per colour scheme, so it can stay readable.
- They're closures, read live: a palette that changes at runtime recolours the pill.

## Logging and diagnostics

```swift
let log = NotchLog.unified(subsystem: "com.example.MyApp")       // or NotchLog { level, message in … }, or .silent
let diagnostics = NotchDiagnostics(log: log)                      // placement and neighbors, for a support report
let neighbors = NotchNeighborMonitor(log: log)
let dock = NotchDock(symbol: "waveform", log: log)
let controller = NotchPanelController(content: content, settings: settings, neighbors: neighbors,
                                      diagnostics: diagnostics, log: log, dock: dock)
```

Nothing is logged globally: pass the same `NotchLog` to each piece. Write it to your developer console with
`NotchLog { level, message in … }`.

## Settings rows

```swift
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
```

Store the settings in your own preferences:

```swift
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
```

- Reading `notch` must read your observable properties, so the pill follows changes.
- Store the enums' raw values (`grow`, `clearMenuBar`, `automatic`…); they never change.
- `NotchPreview` draws a miniature screen around a sample of your body, for a Settings page.

## Tests with in-memory fakes

```swift
@MainActor
func makeTestDock(appID: String = "com.example.Test", bus: InMemoryNotchDockBus = InMemoryNotchDockBus()) -> NotchDock {
    NotchDock(appID: appID, symbol: "circle",
              channel: bus.makeChannel(),                                  // never the real channel
              trust: NotchDockStaticTrust(trusted: nil),                   // trusts everyone on the bus
              settings: NotchDockSettings(storage: InMemoryNotchDockSettingsStorage()),   // never the shared suite
              processes: ManualNotchDockProcessWatcher())
}
```

```swift
@MainActor @Test func aNoticeShowsThePill() {
    let content = NotchContent()
    let pill = NotchViewModel(content: content, settings: InMemoryNotchSettings(), geometry: .fallback)
    content.showing = NotchBody(height: 34) { Text("Hello") }
    content.status = .showing
    #expect(pill.mode == .showing)
    #expect(pill.size(for: .showing).height > 34)
}
```

Use the fakes in tests, previews and any test host: the real dock talks to the docked apps on the Mac and writes the
user's shared settings. More in <doc:Testing>.
