#!/bin/zsh
# Stand-in docked apps for checking the dock live on this Mac (see mesh-peer.swift).
#
#     Tools/mesh-peer.sh build [<folder>]          # builds MeshPeer-red/blue/green.app (default ~/Library/Caches/polytopic-mesh-peer)
#     Tools/mesh-peer.sh run [--style split] [--seconds 8] [--folder <folder>]
#                                                  # runs red (live, then quiet) and blue (quiet, notice, urgent), waits,
#                                                  # quits them and prints their logs
#     Tools/mesh-peer.sh --unregister [<folder>]   # removes the bundles from Launch Services
#
# Signing: with an Apple Development identity when `security find-identity` lists one (MESH_PEER_TEAM=<team id> picks
# that team's; the bundles then pass DeveloperIDTrust's development check, which DEBUG builds have on); otherwise ad hoc,
# and the stand-ins are built with DEBUG and admit each other through the DEBUG-only ad-hoc override. The keychain is
# only read. Signed stand-ins join the real shared dock, so docked apps running on this Mac see them too.
# The folder must be outside Dropbox: Dropbox adds extended attributes that break code signing.
set -euo pipefail

lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
default_out="$HOME/Library/Caches/polytopic-mesh-peer"
here="${0:A:h}"
repo="${here:h}"
names=(red blue green)

refuse_dropbox() {
    if [[ "$1/" == */Dropbox/* || "$1/" == *" Dropbox/"* || "$1" == */Library/CloudStorage/* ]]; then
        echo "mesh-peer: $1 is inside Dropbox; pick a folder outside it (e.g. $default_out)." >&2
        exit 2
    fi
}

identity() {
    # The SHA-1 of an Apple Development identity (of team $MESH_PEER_TEAM when set).
    security find-identity -v -p codesigning 2>/dev/null | grep '"Apple Development' | while read -r _ sha name; do
        cn="${${name#\"}%\"}"
        if [[ -z "${MESH_PEER_TEAM:-}" ]] || security find-certificate -c "$cn" -p 2>/dev/null \
            | openssl x509 -noout -subject 2>/dev/null | grep -q "OU *= *$MESH_PEER_TEAM"; then
            echo "$sha"
            return
        fi
    done
}

build() {
    local out="${1:-$default_out}"
    out="${out:A}"
    refuse_dropbox "$out"
    mkdir -p "$out"
    local sdk="$(xcrun --show-sdk-path --sdk macosx)"
    local flags=(-target arm64-apple-macosx26.0 -sdk "$sdk" -swift-version 6 -Onone -D DEBUG)
    echo "mesh-peer: building PolytopicNotch…"
    swiftc "${flags[@]}" -parse-as-library -module-name PolytopicNotch -emit-library -static -emit-module \
        -emit-module-path "$out/PolytopicNotch.swiftmodule" -o "$out/libPolytopicNotch.a" \
        $repo/Sources/PolytopicNotch/**/*.swift
    swiftc "${flags[@]}" -parse-as-library -I "$out" -L "$out" -lPolytopicNotch -o "$out/mesh-peer" "$here/mesh-peer.swift"

    local sha="$(identity)"
    for name in $names; do
        local app="$out/MeshPeer-$name.app"
        rm -rf "$app"
        mkdir -p "$app/Contents/MacOS"
        cp "$out/mesh-peer" "$app/Contents/MacOS/mesh-peer"
        local adhoc=false
        [[ -z "$sha" ]] && adhoc=true
        cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.example.meshpeer.$name</string>
    <key>CFBundleName</key><string>MeshPeer $name</string>
    <key>CFBundleExecutable</key><string>mesh-peer</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>MeshPeerAdHoc</key><$adhoc/>
</dict>
</plist>
PLIST
        if [[ -n "$sha" ]]; then
            codesign --force --sign "$sha" "$app" >/dev/null
        else
            codesign --force --sign - "$app" >/dev/null
        fi
        echo "$app ($([[ -n "$sha" ]] && echo "Apple Development" || echo "ad hoc, DEBUG override"))"
    done
}

run() {
    local out="$default_out" style="" seconds=8
    while (( $# )); do
        case "$1" in
            --style) style="$2"; shift 2 ;;
            --seconds) seconds="$2"; shift 2 ;;
            --folder) out="$2"; shift 2 ;;
            *) echo "mesh-peer: unknown option $1" >&2; exit 2 ;;
        esac
    done
    out="${out:A}"
    [[ -d "$out/MeshPeer-red.app" ]] || build "$out"
    local style_args=()
    [[ -n "$style" ]] && style_args=(--style "$style")
    rm -f "$out"/red.log "$out"/blue.log
    open -n -g "$out/MeshPeer-red.app" --args --name red --seconds "$seconds" --log "$out/red.log" \
        --script "live:3,quiet:2" "${style_args[@]}"
    sleep 0.4
    open -n -g "$out/MeshPeer-blue.app" --args --name blue --seconds "$seconds" --log "$out/blue.log" \
        --script "quiet:1.5,notice:2,urgent:2"
    sleep $(( seconds + 1 ))
    # They quit themselves; make sure.
    pkill -f "$out/MeshPeer-" 2>/dev/null || true
    for name in red blue; do
        echo "== $name"
        cat "$out/$name.log" 2>/dev/null || echo "(no log)"
    done
}

case "${1:-}" in
    build) shift; build "${1:-}" ;;
    run) shift; run "$@" ;;
    --unregister) for app in "${2:-$default_out}"/*.app(N); do "$lsregister" -u "$app" 2>/dev/null || true; done ;;
    *) echo "usage: Tools/mesh-peer.sh build [<folder>] | run [--style <style>] [--seconds <n>] [--folder <folder>] | --unregister [<folder>]" >&2; exit 2 ;;
esac
