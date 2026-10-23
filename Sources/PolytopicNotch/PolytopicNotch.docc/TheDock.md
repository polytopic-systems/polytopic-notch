# The dock

Several notch apps share the notch instead of making room for each other as strangers.

## Opting in

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

Then add `NotchDockSettingsRows(dock:)` to your Settings page (<doc:Recipes>). The controller does the rest: it runs
the dock while the pill is shown, places your pill in the slot the dock gives it, and decides hover with the others.

| `want` | Use it for |
|---|---|
| `none` | off |
| `quiet` | working, nothing to show |
| `notice` | a short post |
| `live` | a live session the user is following |
| `urgent` | set by the package while `content.prompt` waits |

## Styles

The user picks one; every docked app follows.

| Style | Looks like |
|---|---|
| **Priority** | one app at a time: an urgent question, else the highest `want`, then the earliest, then the user's order |
| **Switcher** | Priority, plus a dot per app in the open pill; a click hands the notch to that app |
| **Split** | each app keeps an ear beside the notch; what they show hangs below, side by side |
| **Merged** | one black pill: the first app at the notch, each next app's part below it |

- Hover and urgent questions are exclusive in every style: one pill open at a time.
- An unanswered urgent question holds the notch for the shared hold (30 s by default, or until answered); then it
  competes as a notice, and an app that isn't granted the notch asks in its floating window.
- Another notch app or a menu bar manager's bar moves every docked app below it.
- Switcher dots: with two or more apps docked, the open pill gets a 26 pt row for them above the body, centred under
  the notch, in every placement. The pill and the layout both make the room; apps change nothing.
- A Split part or a Merged part has its own width: bodies read `bodyTextWidth` (<doc:YourOwnPanel>).

## Shared settings

In `UserDefaults(suiteName: "systems.polytopic.notch")`, kept in step over the dock's messages, so sandboxed and App
Store apps share them too. Keys (never renamed): `notch.sharingStyle`, `notch.urgentHoldSeconds`,
`notch.urgentHoldUntilAnswered`, `notch.appOrder`, `notch.blockedApps`, `notch.updatedAt`, `notch.writer`.

- The newest change wins (a tie goes to the greater writer), so every app settles on the same snapshot.
- Joining isn't a write: a new app never resets everyone to its defaults.
- Snapshots from other apps are sanitized, and a blocked app's are ignored.

## Trust

```swift
var options = DistributedNotchDockChannel.Options()
options.prefix = "com.example.dock"               // your own channel: the shared dock never sees you
let dock = NotchDock(symbol: "waveform",
                     channel: DistributedNotchDockChannel(options: options),
                     trust: CodeSignatureTrust(teamID: "ABCDE12345", bundlePrefix: "com.example."),
                     settings: NotchDockSettings(storage: UserDefaults(suiteName: "com.example.dock")))
```

That keeps a dock to your own team. By default (`DeveloperIDTrust`):

- Any app signed with Developer ID or for the Mac App Store docks, whoever made it. Apple Development builds dock
  when the checking app is a Debug build. Ad hoc and unsigned code never docks.
- Messages carry no content: no text, titles or levels, only wants, modes, sizes, hover and the display. Any local
  process can read them.
- It isn't strong authentication. The worst a hostile signed app can do is make other pills step aside: a question
  is never hidden, an urgent claim is capped by the hold, and the user can block it (`NotchDock.setBlocked`).
- `allowAdHocForTesting` exists only in DEBUG builds and is compiled out of Release.

## Protocol

`DistributedNotificationCenter` with `deliverImmediately`, names `systems.polytopic.notch.v2.<kind>`, a JSON string as
the notification's `object` (the App Sandbox drops ones with `userInfo`).

| Message | When | Carries |
|---|---|---|
| `hello` | the dock starts, wake, a screen change | the sender's announcement; peers answer with `announce` |
| `announce` | a field of the announcement changed | the announcement (``NotchDockAnnouncement``) |
| `style` | the shared settings changed, or an app answers an older snapshot | the settings snapshot |
| `bye` | the dock stopped | the pid and instance; quits are seen by a process-exit watcher |

- Unknown fields are ignored and missing ones default, so minor versions mix. A style an app can't draw falls back to
  Priority for everyone.
- A new major gets new names; apps on different majors don't see each other. For one release after a bump, post on
  both (`DistributedNotchDockChannel.Options.alsoPostOn`).
- The layout is one pure function every app runs on the same announcements (`NotchDockLayout.solve`): no leader, each
  app draws only its own part, rects snapped to the pixel grid so parts in different windows meet exactly.

## Hover

- The layout decides which pill is open; a docked pill is expanded exactly when its slot says so.
- Of two apps hovered at once, the one hovered first stays open until it lets go: never two open pills.
- An open part covers what was under the pointer when its hover began, so opening never leaves a still pointer
  outside it.
- Split: while one pill is open, resting on another app's ear hands the open pill over.
- A panel takes clicks only while hovered and only over its own part; clicks beside it reach the other apps.
