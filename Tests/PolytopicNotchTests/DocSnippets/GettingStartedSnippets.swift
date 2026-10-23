// The code in README.md and GettingStarted.md, verbatim, so it compiles. Nothing here is started: starting a pill would
// show it on this Mac. `DocSnippetGuardTests` checks every Swift block in the docs appears in a file in this folder.

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

// `@main` is left out here (a test target has no entry point); the guard ignores that line.
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
