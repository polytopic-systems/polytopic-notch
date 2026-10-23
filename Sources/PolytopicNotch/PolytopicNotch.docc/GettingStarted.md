# Getting started

Add the package and show a first pill at the notch.

## Add the package

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

macOS 26 or later, Swift 6, no dependencies, no Accessibility or Screen Recording permission.

## Your first pill

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

Start it once the app has launched:

```swift
@main
struct MyApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        MenuBarExtra("My App", systemImage: "waveform") {
            Button("Post a Notice") { delegate.notch.post("Something happened") }
            Button("Quit") { NSApp.terminate(nil) }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let notch = MyNotch()

    func applicationDidFinishLaunching(_ notification: Notification) {
        notch.start()                                 // after launch, not from a SwiftUI initializer
    }
}
```

`post(_:)` is the notice recipe in <doc:Recipes>.

- `NotchContent` is all the pill reads from your app. Change it and the pill follows.
- Keep `MyNotch` for as long as the app runs.
- Started from a `@State` initial value, the controller waits until launch has finished: laying out the pill inside
  SwiftUI's scene update would abort the app.
- On a Mac without a notch, or an external display, the same pill hangs below the menu bar.

## What NotchContent holds

| Field | What it does |
|---|---|
| `status` | `off`, `quiet` (meter and dot), `showing` (the `showing` body drops down), `attention` (showing, in the attention colour) |
| `showing`, `expanded`, `prompt` | the bodies: a notice, the hover panel, a question (``NotchBody``) |
| `symbol`, `title` | your SF Symbol; the title in the band where there's no notch |
| `level` | 0...1, for the meter |
| `busy` | loading bars: something the user waits for |
| `dot`, `lineColor` | your own colours for the status dot and the quiet line |
| `want` | how much you want the notch when apps share it: `none < quiet < notice < live` (<doc:TheDock>) |

## Next

- <doc:Recipes>: notices, panels, live lists, menus, questions, tabs, the dock, themes, logging, Settings, tests.
- <doc:YourOwnPanel>: what a body can read and do.
- `Examples/NotchDemo`: a menu bar app in one file that does all of it. In that folder:
  `swift run --scratch-path ~/Library/Caches/notch-demo-build NotchDemo`.
