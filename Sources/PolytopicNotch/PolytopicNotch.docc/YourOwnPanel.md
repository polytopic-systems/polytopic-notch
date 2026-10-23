# Your own panel

Put any SwiftUI view in the pill.

## Overview

```swift
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
```

```swift
content.expanded = NotchBody(height: 220) { MonitorPanel(model: model) }
```

Tabs, a menu and a live list in the hover panel. Each piece has a recipe in <doc:Recipes>.

| Body | Shows | Clicks |
|---|---|---|
| `showing` | below the notch while `status` is `showing` or `attention` | no: hovering opens `expanded` |
| `expanded` | while the pointer is on the pill, or a menu from it is open | yes |
| `prompt` | a question: in the pill at a notch, else in a floating window | yes |

## Size

```swift
content.expanded = NotchBody(width: 440, height: 200) { HoverPanel() }
content.showing = NotchBody(height: { placement in placement == .menuBar ? 40 : CGFloat(captionLines()) * 20 + 20 }) {
    Text("Captions")
}
```

- `height` is below the band: a number, or a closure of the placement that may read your settings. It's read inside
  observation, so the pill resizes when what it reads changes.
- `width` is optional: 500 showing, 560 expanded, 540 asking by default. `bottomRadius` shapes a `showing` body only.
- The view is centred in its height; frame it with `alignment: .top` to sit at the top.
- Give a panel a fixed height: content that changes height makes the pill jump.
- The panel window caps the pill: 680 × 420 pt alone, 1000 × 520 pt docked. Keep an expanded body under about 300 pt.

## What a body can read

`@Environment(NotchViewModel.self) private var pill`:

| Property | What it is |
|---|---|
| `placement` | `.notch`, `.belowNotch` (another app has the notch) or `.menuBar` (no notch) |
| `isDark` | black pill at a notch, rather than glass below the menu bar |
| `mode` | `hidden`, `quiet`, `showing`, `expanded`, `asking` |
| `bodyTextWidth` | the text width for a `showing` body, steady while the pill animates |
| `dockedBodyWidth` | the width a docked part gives you, `nil` in your own pill |
| `theme`, `metrics`, `geometry` | colours and fonts, fixed sizes, the screen and notch |
| `settings` | the notch settings (`settings.notch.fontSize` is the user's text size) |
| `content`, `level`, `needsAttention` | your content, the meter level, `status == .attention` |
| `isHovering`, `isMenuOpen` | the pointer is on the pill; a menu from it is open |
| `slot`, `showsSwitcherDots`, `switcherRowHeight` | your share of a docked notch, and the Switcher dots' row |

Inside the pill the colour scheme is dark (glass follows the system), so `.primary` and `.secondary` read.

## Rules

- **State lives in your model.** A body exists only while its mode shows; `@State` lasts one opening.
- **Menus:** ``NotchMenuButton`` only. A SwiftUI `Menu` can't tell the pill it's open, and the pill closed under it.
- **No keyboard focus.** The pill never becomes key: no text fields, no shortcuts. Never give an answer a shortcut.
- **Clicks** reach the pill only while it's hovered and only over the pill as drawn; clicks beside it go through.
- **Lists that change** use ``NotchLiveList`` (<doc:LiveLists>).

## Questions in the floating window

```swift
struct ConnectionQuestion: View {
    @Environment(NotchViewModel.self) private var pill: NotchViewModel?    // nil in the floating window

    var body: some View {
        Text("Allow this connection?")
            .frame(width: pill?.bodyTextWidth ?? 300)
    }
}
```

The floating window (``NotchPromptWindowController``) puts no `NotchViewModel` in the environment: a `prompt` body that
reads it must read it as optional.

## When apps share the notch

- **Split**: your `showing` body may get part of the width. Use `bodyTextWidth`, which is that part's width.
- **Merged**: hovering widens the whole stack, so an `expanded` body may be wider than its `width`. Let it stretch.
- **Switcher**: with two or more apps docked, the open pill shows a dot per app in a 26 pt row above your body,
  centred under the notch. The package makes the room; your body keeps its height below the row.
