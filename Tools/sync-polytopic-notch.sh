#!/bin/zsh
# Optional: vendors a tagged release of the PolytopicNotch package into an app (instead of a Swift Package Manager
# dependency, e.g. so CI needs no network), and checks that nobody edited the copy. Copy it into the app's Tools/.
#
#     Tools/sync-polytopic-notch.sh <tag> [--from <checkout or URL>]   copy that tag into Vendor/PolytopicNotch
#     Tools/sync-polytopic-notch.sh --check                            fail if Vendor/PolytopicNotch was edited
#
# The copy is the tag's whole tree, byte for byte, plus a stamp file Vendor/PolytopicNotch/UPSTREAM:
#     tag 0.1.0
#     tree <git rev-parse 0.1.0^{tree}>
# `--check` hashes the folder the way git would (without UPSTREAM) and compares it with the stamp, so an edit made
# here instead of upstream fails the check. Change the package upstream, tag it, sync.
#
# Without --from it uses the sibling checkout ../polytopic-notch when that has the tag, else clones
# https://github.com/polytopic-systems/polytopic-notch.git.
set -euo pipefail

repo_url="https://github.com/polytopic-systems/polytopic-notch.git"
script="${0:t}"
here="${0:A:h}"
root="$(git -C "$here" rev-parse --show-toplevel)"
vendor_rel="Vendor/PolytopicNotch"
vendor="$root/$vendor_rel"
stamp="$vendor/UPSTREAM"

usage() {
    echo "usage: $script <tag> [--from <checkout or URL>] | --check" >&2
    exit 2
}

# The git tree hash of the vendored folder as it is on disk, without the stamp. Uses a throwaway index, so the
# app's own index and working tree are untouched.
vendored_tree() {
    local index
    index="$(mktemp -t polytopic-notch-index)"
    GIT_INDEX_FILE="$index" git -C "$root" read-tree --empty
    GIT_INDEX_FILE="$index" git -C "$root" add -- "$vendor_rel"
    GIT_INDEX_FILE="$index" git -C "$root" rm --cached --quiet --ignore-unmatch -- "$vendor_rel/UPSTREAM" >/dev/null
    GIT_INDEX_FILE="$index" git -C "$root" write-tree --prefix="$vendor_rel/"
    rm -f "$index"
}

stamp_field() {
    awk -v key="$1" '$1 == key { print $2 }' "$stamp"
}

check() {
    if [[ ! -f "$stamp" ]]; then
        echo "sync-polytopic-notch: $vendor_rel/UPSTREAM is missing; run Tools/sync-polytopic-notch.sh <tag>." >&2
        exit 1
    fi
    local tag expected actual
    tag="$(stamp_field tag)"
    expected="$(stamp_field tree)"
    if [[ -z "$tag" || -z "$expected" ]]; then
        echo "sync-polytopic-notch: $vendor_rel/UPSTREAM has no tag or tree line." >&2
        exit 1
    fi
    actual="$(vendored_tree)"
    if [[ "$actual" != "$expected" ]]; then
        echo "sync-polytopic-notch: $vendor_rel differs from PolytopicNotch $tag (tree $actual, expected $expected)." >&2
        echo "Edit upstream only: make the change in polytopic-notch, tag a release, then Tools/sync-polytopic-notch.sh <tag>." >&2
        git -C "$root" status --short -- "$vendor_rel" >&2 || true
        exit 1
    fi
    echo "PolytopicNotch $tag (tree $expected): vendored copy unchanged."
}

sync() {
    local tag="$1" from="$2" source tmp="" tree
    if [[ -z "$from" && -d "$root/../polytopic-notch/.git" ]] \
        && git -C "$root/../polytopic-notch" rev-parse --verify --quiet "refs/tags/$tag" >/dev/null; then
        from="$root/../polytopic-notch"
    fi
    if [[ -n "$from" && -d "$from" ]]; then
        source="$from"
    else
        tmp="$(mktemp -d -t polytopic-notch)"
        git clone --quiet --no-checkout "${from:-$repo_url}" "$tmp/repo"
        source="$tmp/repo"
    fi
    # Releases only: a tag every app can name, never a branch that moves.
    if ! tree="$(git -C "$source" rev-parse --verify --quiet "refs/tags/$tag^{tree}")"; then
        echo "sync-polytopic-notch: no tag $tag in $source." >&2
        if [[ -n "$tmp" ]]; then rm -rf "$tmp"; fi
        exit 1
    fi
    rm -rf "$vendor"
    mkdir -p "$vendor"
    git -C "$source" archive --format=tar "refs/tags/$tag" | tar -x -C "$vendor"
    if [[ -n "$tmp" ]]; then rm -rf "$tmp"; fi
    cat > "$stamp" <<STAMP
# Vendored from $repo_url by Tools/sync-polytopic-notch.sh.
# Don't edit this folder: change the package upstream, tag it, and sync again (Tools/test.sh checks).
tag $tag
tree $tree
STAMP
    local actual
    actual="$(vendored_tree)"
    if [[ "$actual" != "$tree" ]]; then
        echo "sync-polytopic-notch: the copy hashes to $actual, not $tree (a .gitattributes or .gitignore rule in this repo changes it?)." >&2
        exit 1
    fi
    echo "Vendored PolytopicNotch $tag (tree $tree) into $vendor_rel. Commit it: git add $vendor_rel"
}

case "${1:-}" in
    --check) [[ $# -eq 1 ]] || usage; check ;;
    ""|-*) usage ;;
    *)
        tag="$1"; shift
        from=""
        if [[ "${1:-}" == "--from" ]]; then
            [[ $# -eq 2 ]] || usage
            from="$2"
        elif [[ $# -ne 0 ]]; then
            usage
        fi
        sync "$tag" "$from"
        ;;
esac
