# Changelog

PolytopicNotch follows [semantic versioning](https://semver.org): a major release may break the API or the dock
protocol; minor and patch releases don't. Apps on different dock protocol majors don't dock together.

## 1.1.0 (unreleased)

Panels in the pill. Adds API; nothing changes for apps that don't use it.

- **`NotchTabBar`**: ready-made tabs for a panel in the pill (equal tabs, the selected one semibold on a lighter fill),
  with word or view labels. It fills the width it's given and reads in the black pill and in the glass bar.
- **The Switcher dots get a row of their own**, 26 pt above the open body and centred under the notch, in every
  placement. At the notch they sat in the band beside the status dot, crowding a body's top-right buttons; below
  another app's notch they covered the body's top-right corner; with "Keep the menu bar clear" they weren't drawn at
  all. The pill counts the row in its expanded size and the dock's layout adds it to the open slot (apps don't
  announce it). `NotchMetrics.switcherRow`, `NotchDockMetrics.switcherRow`, `NotchViewModel.switcherRowHeight` and
  `showsSwitcherDots` (now public).
- **The article "Your own panel"** (`YourOwnPanel.md`): putting any view in the pill, sizes, what a body reads from
  the environment, state, clicks, menus, live lists, questions in the floating window, docked widths, the dots, tabs.
- **Docs rewritten around copy-paste code**: a Recipes article (notices, panels, live lists, menus, questions, tabs,
  the dock, the block list, themes, logging, Settings rows, tests), and every article leads with code. Every Swift
  block in the README and the articles is compiled by the tests (`DocSnippetGuardTests`).
- **The example app no longer aborts at launch.** `NotchPanelController.start()` called while the app is still
  launching (a SwiftUI `App`'s `@State` initial value) waits for launching to finish before it lays out or shows the
  pill; laying it out inside SwiftUI's scene update aborted the app. NotchDemo now starts the pill from
  `applicationDidFinishLaunching`, and its panel has Events and Notices tabs.

## 1.0.0 (unreleased)

The first public release.

- **The dock is open to every app** signed with Developer ID or for the Mac App Store, whoever made it
  (`DeveloperIDTrust`, the new default). Apple Development builds dock in DEBUG. `CodeSignatureTrust(teamID:bundlePrefix:)`
  keeps a dock to one team; it no longer has a default team.
- **Block list**: the user can keep an app out of the dock (`NotchDock.setBlocked`, "Don't Dock with This App" in
  `NotchDockAppList`). It checks a pid's real bundle ID, not only the claimed one; a blocked app leaves the dock on its own
  side too and can't let itself back in.
- **Dock protocol v2** (breaking): notification names `systems.polytopic.notch.v2.<kind>`, the payload as the
  notification's `object` instead of `userInfo`, so sandboxed apps can dock. Version 1 isn't read.
- **Shared settings travel in the dock's messages**, stamped and newest-wins, so sandboxed and App Store apps share
  them. The suite is now `systems.polytopic.notch` (breaking: settings stored by 0.x aren't read).
- The style picker's caption is a parameter (`NotchDockSettingsRows(dock:caption:)`).
- `PolytopicNotchVersion` for diagnostics.
- An example app (`Examples/NotchDemo`), a DocC catalog, CI, and dual licensing (GPL v3 or commercial).

## 0.3.0

- Live lists: `NotchLiveFeed`, `NotchLiveList`, `NotchLiveFollow`, `.notchLiveAction()`.

## 0.2.2

- Dock hover: the layout decides which pill is open, one at a time; hover hands over without ping-pong; panels take
  clicks only over their own part. Before, a hover that moved a part under a still pointer fed back on itself: a
  Switcher dot click's claim lapsed and the claimer flashed back every half second; a Merged part closing pulled the
  part below up from under the pointer; a Split pill narrower than its half closed and reopened; and a hovered panel
  took every click over its whole 1000 × 520 canvas for up to 350 ms after the pointer left.

## 0.2.1

- `pillShowsPrompt` is false while the pill steps aside.

## 0.2.0

- The dock: apps share the notch in four styles (Priority, Switcher, Split, Merged), with an urgent hold and a user order.

## 0.1.0

- The pill, its placement and looks, neighbor detection, the floating question window, menus and Settings rows.
