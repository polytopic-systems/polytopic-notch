#!/bin/zsh
# Builds stand-in app bundles for other notch apps and menu bar managers (see notch-standin.swift), for
# the opt-in live test:
#     Tools/notch-standins.sh [<output folder>]
#     NOTCH_STANDINS_DIR=<output folder> swift test --scratch-path ~/Library/Caches/polytopic-notch-build --filter NotchStandInLiveTests
# The default folder is ~/Library/Caches/notch-standins. It must be outside Dropbox: Dropbox adds extended
# attributes that break code signing.
# Afterwards, `Tools/notch-standins.sh --unregister [<output folder>]` removes them from Launch Services so
# the borrowed bundle IDs don't linger.
set -euo pipefail

lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
default_out="$HOME/Library/Caches/notch-standins"

if [[ "${1:-}" == "--unregister" ]]; then
    for app in "${2:-$default_out}"/*.app(N); do "$lsregister" -u "$app" 2>/dev/null || true; done
    exit 0
fi

out="${1:-$default_out}"
out="${out:A}"
# A Dropbox folder is "Dropbox" or "<Team> Dropbox" (or lives under ~/Library/CloudStorage); match folder names,
# not any path that merely mentions the word.
if [[ "$out/" == */Dropbox/* || "$out/" == *" Dropbox/"* || "$out" == */Library/CloudStorage/* ]]; then
    echo "notch-standins: $out is inside Dropbox; pick a folder outside it (e.g. $default_out)." >&2
    exit 2
fi
here="${0:A:h}"
mkdir -p "$out"
swiftc -O -o "$out/standin" "$here/notch-standin.swift"

# profile  bundle ID (the real app's where it has a profile)  name
standins=(
    boring    theboringteam.boringnotch          "Boring Notch stand-in"
    atoll     com.Ebullioscopic.Atoll            "Atoll stand-in"
    notchdrop wiki.qaq.NotchDrop                 "NotchDrop stand-in"
    notchi    com.ruban.notchi                   "Notchi stand-in"
    dnk       com.example.standin.dynamicnotch   "DynamicNotch stand-in"
    island    com.example.standin.agentisland    "Agent Island stand-in"
    generic   com.example.standin.genericnotch   "Generic Notch stand-in"
    wide      com.example.standin.widestrip      "Wide Strip stand-in"
    popover   com.example.standin.popover        "Popover stand-in"
    ice       com.jordanbaird.Ice                "Ice stand-in"
)

for profile bundle name in "${standins[@]}"; do
    app="$out/$profile.app"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS"
    cp "$out/standin" "$app/Contents/MacOS/standin"
    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$bundle</string>
    <key>CFBundleName</key><string>$name</string>
    <key>CFBundleExecutable</key><string>standin</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
    codesign --force --sign - "$app" >/dev/null 2>&1
    echo "$app ($bundle)"
done
echo "Run the live test with: NOTCH_STANDINS_DIR=$out swift test --scratch-path ~/Library/Caches/polytopic-notch-build --filter NotchStandInLiveTests"
