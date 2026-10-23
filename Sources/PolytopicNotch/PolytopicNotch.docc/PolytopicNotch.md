# ``PolytopicNotch``

A pill that hangs from the MacBook notch, for your Mac app.

## Overview

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
```

You set what to show on ``NotchContent``; ``NotchPanelController`` places the pill, sizes and animates it, opens it on
hover, and keeps it clear of other notch apps and menu bar managers. Questions the pill can't show float in a window
(``NotchPromptWindowController``). Without a notch, the pill hangs below the menu bar. Apps that opt in share the
notch through ``NotchDock``.

Start with <doc:GettingStarted>, then <doc:Recipes>.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:Recipes>
- ``NotchContent``
- ``NotchBody``
- ``NotchPanelController``
- ``NotchPromptWindowController``

### Panels, lists and menus

- <doc:YourOwnPanel>
- ``NotchTabBar``
- <doc:LiveLists>
- ``NotchLiveFeed``
- ``NotchLiveList``
- ``NotchLiveFollow``
- ``NotchMenuButton``
- ``ClosureMenuItem``

### Sharing the notch

- <doc:TheDock>
- ``NotchDock``
- ``NotchWant``
- ``NotchSharingStyle``
- ``NotchDockSettings``
- ``NotchDockSharedSettings``
- ``NotchDockTrust``
- ``DeveloperIDTrust``
- ``CodeSignatureTrust``
- ``NotchDockSettingsRows``

### Settings and looks

- ``NotchSettings``
- ``NotchSettingsStore``
- ``InMemoryNotchSettings``
- ``NotchTheme``
- ``NotchDisplayPicker``
- ``NotchSharingPicker``
- ``NotchNeighborRows``
- ``NotchOwnLookRows``
- ``NotchPreview``

### Other notch apps and menu bar managers

- <doc:HowThePillBehaves>
- ``NotchNeighborMonitor``

### Logging, diagnostics and tests

- <doc:Testing>
- <doc:Vendoring>
- ``NotchLog``
- ``NotchDiagnostics``
- ``InMemoryNotchDockBus``
- ``NotchDockStaticTrust``
- ``InMemoryNotchDockSettingsStorage``
- ``ManualNotchDockProcessWatcher``
