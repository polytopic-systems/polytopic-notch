#!/bin/zsh
# Wraps the demo into app bundles with their own bundle IDs and signs them, so two copies can share the notch.
#
#     ./make-app.sh [--identity "<codesigning identity>"] [--out <folder>] [<name> ...]
#
# Names default to "orange" and "teal": NotchDemo-orange.app (com.example.NotchDemo.orange) and NotchDemo-teal.app.
# The dock admits only apps signed for shipping (Developer ID, Mac App Store) and, in Debug builds, Apple Development;
# pass one of your identities (`security find-identity -v -p codesigning` lists them). Without one the bundles are
# signed ad hoc: they run, but they don't dock with each other. Open them from Finder or with `open`.
# The output folder must not be synced (Dropbox, iCloud Drive): extended attributes there break code signing.
set -euo pipefail

here="${0:A:h}"
out="$HOME/Library/Caches/notch-demo"
identity="-"
names=()
while (( $# )); do
    case "$1" in
        --identity) identity="$2"; shift 2 ;;
        --out) out="$2"; shift 2 ;;
        -h|--help) sed -n 2,11p "$0"; exit 0 ;;
        *) names+=("$1"); shift ;;
    esac
done
(( ${#names} )) || names=(orange teal)
out="${out:A}"
if [[ "$out/" == *Dropbox* || "$out" == */Library/CloudStorage/* || "$out" == */Mobile\ Documents/* ]]; then
    echo "make-app: $out is in a synced folder; pick one outside it (e.g. ~/Library/Caches/notch-demo)." >&2
    exit 2
fi

configuration=release
[[ "$identity" == "-" || "$identity" == *"Apple Development"* ]] && configuration=debug
swift build -c "$configuration" --package-path "$here" --scratch-path "$out/build"
binary="$(swift build -c "$configuration" --package-path "$here" --scratch-path "$out/build" --show-bin-path)/NotchDemo"

for name in $names; do
    app="$out/NotchDemo-$name.app"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS"
    cp "$binary" "$app/Contents/MacOS/NotchDemo"
    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.example.NotchDemo.$name</string>
    <key>CFBundleName</key><string>NotchDemo $name</string>
    <key>CFBundleExecutable</key><string>NotchDemo</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
    codesign --force --options runtime --sign "$identity" "$app" >/dev/null
    echo "$app ($([[ "$identity" == "-" ]] && echo "ad hoc: runs, doesn't dock" || echo "$identity"))"
done
