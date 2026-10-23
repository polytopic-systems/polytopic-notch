# Testing

Test your notch without touching the real dock or the user's settings, and run the package's own tests.

## Testing your app

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

- Use the fakes in tests, previews and any app running as a test host: the real dock talks to the docked apps on the
  Mac and writes the user's shared settings.
- Several test docks share one `InMemoryNotchDockBus`; `bus.flush()` delivers their messages.
- `InMemoryNotchSettings` and `NotchLog.silent` for the pill's settings and log.
- `NotchLiveFeed(edge:timing:now:)` takes a clock, so live lists test without waiting.
- To look at the pill, render it offscreen (`ImageRenderer`, or a window parked off every screen captured with
  `cacheDisplay(in:to:)`). Glass comes out blank offscreen.

## The package's tests

```bash
swift test --scratch-path ~/Library/Caches/polytopic-notch-build
NOTCH_RENDER_DIR=~/Library/Caches/notch-renders swift test --scratch-path ~/Library/Caches/polytopic-notch-build --filter Render
swift test -c release -Xswiftc -enable-testing --scratch-path ~/Library/Caches/polytopic-notch-build-release --filter Trust
```

- Keep the scratch path out of Dropbox and iCloud Drive: their extended attributes break code signing.
- `NOTCH_RENDER_DIR` writes the render tests' PNGs: every look of the pill, every dock style and part, the tab bar,
  the Settings rows. The dock renders also check pixels (Merged joints, the Split slit).
- The Release run checks the ad hoc override is compiled out.
- `DocSnippetGuardTests` checks every Swift block in the README and these articles is in
  `Tests/PolytopicNotchTests/DocSnippets`, which compiles. A block that's deliberately incomplete starts with
  `// fragment`.
- Hover walks (`NotchDockHoverTests`) drive two or three real controllers with a scripted pointer and check that
  nothing flickers, one pill is open, and no panel takes clicks it shouldn't.

## Live tests, on purpose

```bash
Tools/mesh-peer.sh build                             # signs with your Apple Development identity if you have one
Tools/mesh-peer.sh run --style split                 # two stand-in docked apps for a few seconds
Tools/notch-standins.sh                              # build stand-ins for other notch apps
NOTCH_STANDINS_DIR=~/Library/Caches/notch-standins swift test --scratch-path ~/Library/Caches/polytopic-notch-build --filter StandIn
Tools/notch-standins.sh --unregister
```

- They put real windows over the notch, and signed mesh peers join the real shared dock.
- With the real Bartender running, a live test checks it's still handled as before.
