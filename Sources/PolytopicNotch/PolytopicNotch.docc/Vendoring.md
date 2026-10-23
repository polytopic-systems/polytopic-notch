# Vendoring a release

Keep a copy of a tagged release in your repository instead of a package dependency.

## Overview

```bash
Tools/sync-polytopic-notch.sh 1.1.0          # copies the tag's tree into Vendor/PolytopicNotch, writes UPSTREAM
git add Vendor/PolytopicNotch && git commit -m "PolytopicNotch 1.1.0"
```

```yaml
# project.yml (XcodeGen). In Xcode: File › Add Package Dependencies › Add Local…
packages:
  PolytopicNotch:
    path: Vendor/PolytopicNotch
targets:
  App:
    dependencies:
      - package: PolytopicNotch
```

- Why: CI needs no network or credentials for it, and `Package.resolved` doesn't change.
- Copy `Tools/sync-polytopic-notch.sh` into your app's `Tools/`. It uses `../polytopic-notch` when that checkout has
  the tag, else it clones the public repository; `--from <checkout or URL>` picks another.

## The check

```bash
Tools/sync-polytopic-notch.sh --check
```

Run it in your test script, before building. It fails when the copy isn't byte for byte the tag's tree: someone
edited it. Change the package upstream (or in a fork), tag it, and sync.

`Vendor/PolytopicNotch/UPSTREAM` is the stamp it checks:

```
tag 1.1.0
tree 3f1c…  (git rev-parse 1.1.0^{tree}, 40 hex digits)
```
