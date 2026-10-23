# How the pill behaves, and why

Levels, clicks, hover timing, other notch apps and menu bar managers.

## Overview

| What | How | Why |
|---|---|---|
| Window level | 27 (`.mainMenu + 3`) when the notch is ours, 25 while sharing it, 100 while hovered | neighbors open over us; clicks reach us; pop-up menus (101) stay on top |
| Clicks | only while hovered, only over the pill as drawn | a transparent window that takes mouse events takes them over its whole frame |
| Hover | opens after 140 ms, closes 350 ms after leaving | passing over the notch on the way to a menu doesn't pop it open |
| Option-hover | hands a shared notch to the other app until the pointer leaves | so the other app's panel can be used |
| Status dot pulse | Core Animation, played by the window server | a SwiftUI `repeatForever` cost about 9% CPU |

## Other notch apps

- Known apps are matched by bundle ID prefix; unknown ones by a window hanging from the top edge over the notch, seen
  twice 0.3 s apart, then remembered until that app quits. `com.apple.*`, full-width strips, popovers and full-screen
  overlays never count.
- With one there, the pill hangs just below the notch (setting: `sharing`). A menu bar manager's bar of hidden items
  (Bartender, Ice, Thaw…) pushes it under the bar while open.
- The window list is read twice a second only while something of ours shows near the notch; otherwise every 10 s.
- Agent apps (most notch apps) don't post launch and quit notifications, so the monitor watches the running
  applications list instead.

## The menu bar

- On macOS 27 the menu bar is one window, so the free space beside the notch can't be measured without extra
  permissions. That's why "Keep the menu bar clear" (`pillShape`) and the indicator position are settings.
- The package never moves or hides other apps' menu bar items and asks for no Accessibility or Screen Recording
  permission.
