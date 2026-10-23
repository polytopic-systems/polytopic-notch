# Contributing

Thanks for helping. Bug reports, ideas and pull requests are all welcome.

## Before you start

- **Bugs**: open an issue with the macOS version, the Mac (notch or not, displays), the other notch apps and menu bar
  managers running, what you did and what happened. A screen recording helps a lot.
- **Larger changes** (a new dock style, a new public type): open an issue first, so we can agree on the shape before
  you spend time on it.
- **The CLA**: your first pull request asks you to sign the [Contributor License Agreement](CLA.md). It lets the
  project offer your code under both the GPL v3 and the commercial license; you keep your copyright.

## Building and testing

```bash
swift build --scratch-path ~/Library/Caches/polytopic-notch-build
swift test --scratch-path ~/Library/Caches/polytopic-notch-build
swift build --package-path Examples/NotchDemo --scratch-path ~/Library/Caches/notch-demo-build
```

Keep build folders out of synced folders (Dropbox, iCloud Drive). Some tests put a transparent panel at the notch for
a moment; that's expected. `NOTCH_RENDER_DIR=<folder>` writes render PNGs, the way to look at a visual change.

## What a good pull request has

- Tests for what it changes. Logic goes in pure types with their own tests (the dock layout, the live-list follow
  algorithm and the codec are examples); views stay thin.
- No new dependencies, no timers that run while nothing shows, no new permissions (Accessibility, Screen Recording).
- Dock changes: messages carry no content, the layout stays one pure function every app runs, and anything that
  changes the wire format waits for a major version.
- Public API: documented, with every parameter described (the DocC build has no warnings).
- A line in `CHANGELOG.md` under the next version.

## Code of conduct

Be kind and assume good intent. Harassment isn't tolerated; maintainers may remove comments and block people who don't
follow this.
