# PolytopicNotch

A pill that hangs from the MacBook notch, for your Mac app. You say what to show; the package places it, animates it,
opens it on hover, asks your questions, and keeps out of the way of other notch apps.

Swift package · macOS 26 or later · Swift 6 · no dependencies · by [Polytopic Systems](https://polytopic.systems)

## Install

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/polytopic-systems/polytopic-notch.git", from: "1.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "PolytopicNotch", package: "polytopic-notch")]),
]
```

In Xcode: File › Add Package Dependencies…, paste the URL, Up to Next Major Version from 1.1.0.

## Quick start

```swift
import AppKit
import PolytopicNotch
import SwiftUI

@MainActor
final class MyNotch {
    let content = NotchContent()
    let settings = InMemoryNotchSettings()            // or your own NotchSettingsStore (Recipes › Settings)
    let neighbors = NotchNeighborMonitor()
    lazy var controller = NotchPanelController(content: content, settings: settings, neighbors: neighbors)
    lazy var prompts = NotchPromptWindowController(content: content) { [unowned self] in controller.pillShowsPrompt }

    func start() {
        content.symbol = "waveform"
        content.title = "My App"
        content.status = .quiet                       // a meter and a status dot beside the notch
        content.expanded = NotchBody(height: 160) { Text("Shown on hover").padding() }
        controller.start()
        observe { [prompts] in prompts.update() }     // a question the pill can't show floats in a window
    }
}

/// Runs `apply` again whenever an observable value it read changes.
@MainActor
func observe(_ apply: @escaping @MainActor () -> Void) {
    withObservationTracking(apply) { Task { @MainActor in observe(apply) } }
}
```

Call `start()` from `applicationDidFinishLaunching`. Then post a notice:

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

## Recipes

Copy-paste code, compiled by the package's tests, in
[Recipes](Sources/PolytopicNotch/PolytopicNotch.docc/Recipes.md):

| Recipe | Uses |
|---|---|
| A quiet indicator | `content.status = .quiet`, `level`, `dot`, `busy` |
| Post a notice | `content.showing` |
| A hover panel | `content.expanded` |
| A live list | `NotchLiveFeed`, `NotchLiveList`, `.notchLiveAction()` |
| A menu in the pill | `NotchMenuButton`, `ClosureMenuItem` |
| A question with buttons | `content.prompt`, `NotchPromptWindowController` |
| Tabs | `NotchTabBar` |
| Opt into the dock | `NotchDock`, `content.want` |
| The block list | `NotchDock.setBlocked` |
| A theme | `NotchTheme` |
| Logging and diagnostics | `NotchLog`, `NotchDiagnostics` |
| Settings rows | `NotchDisplayPicker`, `NotchSharingPicker`, `NotchOwnLookRows`, `NotchDockSettingsRows`, `NotchSettingsStore` |
| Tests with in-memory fakes | `InMemoryNotchDockBus`, `NotchDockStaticTrust`, `InMemoryNotchDockSettingsStorage` |

## What it does for you

- **Places the pill** at the notch, below another app's notch, or below the menu bar on a Mac without one.
- **Makes room** for other notch apps and menu bar managers (Bartender, Ice…); Option-hover hands the notch over.
  No Accessibility or Screen Recording permission, and it never moves other apps' menu bar items.
- **Never loses a question**: when the pill can't show it, a small floating window asks.
- **Live lists** that hold still while the user points at a row's buttons or scrolls back.
- **The dock**: apps using this package share the notch in the style the user picks (Priority, Switcher, Split,
  Merged), whoever made them.
- **Nothing ticks while idle**: no per-frame timers, no polling while nothing shows.

## The example app

```bash
cd Examples/NotchDemo
swift run --scratch-path ~/Library/Caches/notch-demo-build NotchDemo
./make-app.sh --identity "Developer ID Application: …"     # two signed copies that share the notch
```

A menu bar app in one file: a notice, a live session with tabs and a live list, a menu, a question, the dock's
settings.

## Documentation

The DocC catalog is `Sources/PolytopicNotch/PolytopicNotch.docc` (in Xcode: Product › Build Documentation).

- [Getting started](Sources/PolytopicNotch/PolytopicNotch.docc/GettingStarted.md): add the package, a first pill.
- [Recipes](Sources/PolytopicNotch/PolytopicNotch.docc/Recipes.md): the common tasks.
- [Your own panel](Sources/PolytopicNotch/PolytopicNotch.docc/YourOwnPanel.md): sizes, what a body can read, rules.
- [Live lists](Sources/PolytopicNotch/PolytopicNotch.docc/LiveLists.md): when a list holds and follows.
- [The dock](Sources/PolytopicNotch/PolytopicNotch.docc/TheDock.md): styles, shared settings, trust, the protocol.
- [How the pill behaves](Sources/PolytopicNotch/PolytopicNotch.docc/HowThePillBehaves.md): levels, clicks, hover,
  other notch apps.
- [Testing](Sources/PolytopicNotch/PolytopicNotch.docc/Testing.md): fakes, and the package's own tests.
- [Vendoring a release](Sources/PolytopicNotch/PolytopicNotch.docc/Vendoring.md): a copy in your repository.

## The dock and trust

Any app signed with Developer ID or for the Mac App Store can join the dock; your Debug builds signed with Apple
Development dock too; ad hoc and unsigned builds can't. Messages carry no content, only sizes, modes and how much each
app wants the notch. A badly behaved app can at worst make the others step aside: it can't hide a question, and the
user can block it. To dock only with your own team, use `CodeSignatureTrust(teamID:)` and a channel prefix of your
own ([The dock](Sources/PolytopicNotch/PolytopicNotch.docc/TheDock.md)).

## License

PolytopicNotch is dual-licensed:

- **[GNU GPL v3](LICENSE)** for apps released under the GPL v3 (or a compatible license), with their source code.
- **A commercial license** for apps that aren't open source: paid or free closed-source apps, and anything on the Mac
  App Store (the App Store's terms add restrictions the GPL doesn't allow). Indie, Team and Enterprise tiers:
  [COMMERCIAL-LICENSE.md](COMMERCIAL-LICENSE.md).

If you won't publish your app's source under the GPL, you need the commercial license.

Copyright © 2026 Tech on Tires, LLC (Polytopic Systems).

## Contributing

Issues and pull requests are welcome. Pull requests need a signed [Contributor License Agreement](CLA.md) (a bot asks
on your first one), so contributions can be offered under both licenses. See [CONTRIBUTING.md](CONTRIBUTING.md).
Security problems: [SECURITY.md](SECURITY.md).

## Tests

```bash
swift test --scratch-path ~/Library/Caches/polytopic-notch-build
```

Keep the scratch path out of Dropbox and iCloud Drive: their extended attributes break code signing. More in
[Testing](Sources/PolytopicNotch/PolytopicNotch.docc/Testing.md).
