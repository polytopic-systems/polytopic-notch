#!/bin/zsh
# Updates a String Catalog from the code: builds the scheme with the compiler's string extraction on
# (SWIFT_EMIT_LOC_STRINGS), then merges what it found into the catalog with `xcstringstool sync`. New strings are
# added in English, strings no longer used are marked stale, and translations are kept.
#
#     Tools/l10n/extract.sh <catalog.xcstrings> <scheme> [<target>] [-- <extra xcodebuild arguments>]
#
# <target> limits the merge to one target's strings (default: the scheme's name). Run from the folder that holds
# Package.swift or the .xcodeproj. Then Tools/l10n/translate.mjs and Tools/l10n/check.mjs.
set -euo pipefail
catalog="${1:?usage: extract.sh <catalog.xcstrings> <scheme> [<target>] [-- <xcodebuild args>]}"
scheme="${2:?usage: extract.sh <catalog.xcstrings> <scheme> [<target>]}"
target="${3:-$scheme}"
[[ "$target" == "--" ]] && target="$scheme"
extra=()
if (( ${@[(I)--]} )); then extra=("${@[${@[(I)--]}+1,-1]}"); fi
derived="${TMPDIR:-/tmp}/l10n-extract-${scheme}"
[[ -f "$catalog" ]] || print -r -- '{ "sourceLanguage" : "en", "strings" : { }, "version" : "1.0" }' > "$catalog"
xcodebuild build -scheme "$scheme" -destination 'platform=macOS' -derivedDataPath "$derived" -quiet \
    SWIFT_EMIT_LOC_STRINGS=YES CODE_SIGNING_ALLOWED=NO "${extra[@]}" >/dev/null
data=(${(f)"$(find "$derived/Build/Intermediates.noindex" -path "*/${target}.build/*" -path '*/arm64/*' -name '*.stringsdata' | sort)"})
(( ${#data} )) || { echo "extract.sh: no strings data for target $target" >&2; exit 1; }
xcrun xcstringstool sync "$catalog" --stringsdata "${data[@]}"
echo "l10n: ${catalog:t} has $(xcrun xcstringstool print "$catalog" | grep -c . || true) keys (${#data} files from $target)"
