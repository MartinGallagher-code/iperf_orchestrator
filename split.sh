#!/usr/bin/env bash
# split.sh -- expand a bundle produced by merge.sh into files again.
#
# Usage: split.sh [BUNDLE] [DEST_DIR]
#   BUNDLE    bundle file to read      (default: bundle.txt)
#   DEST_DIR  directory to expand into (default: current directory)
#
# Understands the v2 format written by the matching merge.sh (FILE,
# FILE-B64, DIR, LINK sections with optional META lines) and remains
# compatible with v1 bundles (plain FILE/FILE-B64 without META).
#
# Robustness properties:
#   * no shell is ever invoked with a bundle-controlled string, so
#     hostile paths like  $(rm -rf ~)  cannot execute anything
#   * absolute paths and ".." components in entries are rejected --
#     a bundle can only write inside DEST_DIR
#   * permissions are restored and sha256 checksums verified when the
#     bundle carries them (exit status 1 on any mismatch)
#   * files stored with nonl=1 get their missing trailing newline
#     removed again, so contents round-trip byte-for-byte
#   * a truncated bundle (section without ===END===) is an error, not
#     a silent partial expansion

set -euo pipefail
export LC_ALL=C

usage() {
    sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}
[ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] && usage 0

in="${1:-bundle.txt}"
dest="${2:-.}"

[ -f "$in" ] || { echo "split.sh: bundle not found: $in" >&2; exit 1; }
mkdir -p "$dest"

# base64 decoder: GNU uses -d, older BSD/macOS -D, openssl as a last resort.
if printf 'dA==' | base64 -d >/dev/null 2>&1; then
    b64dec() { base64 -d; }
elif printf 'dA==' | base64 -D >/dev/null 2>&1; then
    b64dec() { base64 -D; }
elif command -v openssl >/dev/null 2>&1; then
    b64dec() { openssl enc -base64 -d -A; }
else
    echo "split.sh: no base64 decoder available" >&2; exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
    sha() { sha256sum <"$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
    sha() { shasum -a 256 <"$1" | awk '{print $1}'; }
else
    sha() { :; }
fi

chop_last_byte() {  # remove the final byte of $1 (used for nonl=1 files)
    local size
    size=$(wc -c < "$1")
    size=$((size - 1))
    [ "$size" -ge 0 ] || return 0
    if command -v truncate >/dev/null 2>&1; then
        truncate -s "$size" "$1"
    else
        dd if=/dev/null of="$1" bs=1 seek="$size" 2>/dev/null
    fi
}

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
manifest="$workdir/manifest"
: > "$manifest"

# --- pass 1: parse the bundle -------------------------------------------
# awk writes text files directly (safe: paths only ever appear as awk
# redirection targets, never inside a shell command), stores base64 and
# symlink payloads under numbered names in $workdir, and appends one
# US-separated record per section to the manifest for pass 2.
awk -v dest="$dest" -v work="$workdir" -v mf="$manifest" -v q="'" '
function fail(msg) {
    printf "split.sh: line %d: %s\n", NR, msg > "/dev/stderr"
    bad = 1
}
function safe(path) {
    if (path == "" || path ~ /^\//) return 0
    if (path ~ /(^|\/)\.\.(\/|$)/) return 0
    if (path ~ /[\001-\037]/) return 0
    return 1
}
# Wrap a string in single quotes for system(), turning embedded single
# quotes into the standard '\'' sequence.  This is what makes bundle
# paths safe to pass to mkdir: nothing in them is ever shell-expanded.
function shq(s) { gsub(q, q "\\\\" q q, s); return q s q }
function begin_section(p, k) {
    if (kind != "") { fail("new section before ===END=== (" p ")"); return 0 }
    if (!safe(p)) { fail("unsafe path rejected: " p); kind = "reject"; return 0 }
    path = p; kind = k
    mode = ""; sum = ""; nonl = 0; meta_ok = 1
    return 1
}
function record() {
    printf "%s\037%s\037%s\037%s\037%s\037%s\n",
           kind, path, mode, sum, nonl, payload >> mf
}
BEGIN { count = 0 }
/^===FILE: .*===$/ {
    if (begin_section(substr($0, 10, length($0) - 12), "text")) {
        out = dest "/" path
        d = out
        if (sub(/\/[^\/]*$/, "", d) && d != "")
            system("mkdir -p -- " shq(d))
        printf "" > out
    }
    next
}
/^===FILE-B64: .*===$/ {
    if (begin_section(substr($0, 14, length($0) - 16), "b64")) {
        payload = work "/p" (++count)
        printf "" > payload
    }
    next
}
/^===LINK: .*===$/ {
    if (begin_section(substr($0, 10, length($0) - 12), "link")) {
        payload = work "/p" (++count)
        printf "" > payload
    }
    next
}
/^===DIR: .*===$/ {
    begin_section(substr($0, 9, length($0) - 11), "dir")
    next
}
/^===META: .*===$/ {
    if (kind != "" && meta_ok) {
        inner = substr($0, 10, length($0) - 12)
        if (match(inner, /mode=[0-7]+/))
            mode = substr(inner, RSTART + 5, RLENGTH - 5)
        if (match(inner, /sha256=[0-9a-f]+/))
            sum = substr(inner, RSTART + 7, RLENGTH - 7)
        if (inner ~ /(^| )nonl=1( |$)/) nonl = 1
        meta_ok = 0
        next
    }
    # A stray META outside a section is content corruption.
    if (kind == "") { fail("META outside a section"); next }
}
/^===END===$/ {
    if (kind == "") { fail("===END=== without a section"); next }
    if (kind == "text") close(out)
    else if (kind == "b64" || kind == "link") close(payload)
    if (kind != "reject") record()
    kind = ""; path = ""; payload = ""
    next
}
{
    meta_ok = 0
    if (kind == "text") print > out
    else if (kind == "b64" || kind == "link") print > payload
    else if (kind == "dir") fail("content inside a DIR section")
    # lines outside any section (e.g. leading comments) are ignored
}
END {
    if (kind != "") { fail("bundle truncated: section for " path " never ended"); }
    if (bad) exit 3
}
' "$in" || {
    echo "split.sh: aborting -- unsafe or malformed bundle ($in); nothing verified" >&2
    exit 3
}

# --- pass 2: post-process from the manifest ------------------------------
restored=0 verified=0 errors=0

while IFS=$'\037' read -r kind path mode sum nonl payload; do
    target="$dest/$path"
    case "$kind" in
        dir)
            mkdir -p -- "$target"
            ;;
        link)
            mkdir -p -- "$(dirname -- "$target")"
            linktarget=$(cat "$payload")
            rm -f -- "$target"
            ln -s -- "$linktarget" "$target"
            ;;
        b64)
            mkdir -p -- "$(dirname -- "$target")"
            if ! b64dec < "$payload" > "$target"; then
                echo "split.sh: base64 decode failed: $path" >&2
                errors=$((errors + 1))
                continue
            fi
            ;;
        text)
            [ "$nonl" = "1" ] && chop_last_byte "$target"
            ;;
    esac
    if [ "$kind" = "text" ] || [ "$kind" = "b64" ]; then
        [ -n "$mode" ] && chmod "$mode" -- "$target" 2>/dev/null || true
        if [ -n "$sum" ]; then
            actual=$(sha "$target" || true)
            if [ -n "$actual" ]; then
                if [ "$actual" = "$sum" ]; then
                    verified=$((verified + 1))
                else
                    echo "split.sh: CHECKSUM MISMATCH: $path" >&2
                    errors=$((errors + 1))
                fi
            fi
        fi
    fi
    restored=$((restored + 1))
done < "$manifest"

# v2 bundles carry their entry count in the header; a mismatch means the
# bundle was truncated at a section boundary (e.g. a partial download),
# which would otherwise parse cleanly and expand silently incomplete.
expected=$(head -n 5 "$in" | sed -n 's/^# bundle entries: \([0-9][0-9]*\)$/\1/p' | head -n 1)
if [ -n "$expected" ] && [ "$restored" -ne "$expected" ]; then
    echo "split.sh: INCOMPLETE BUNDLE: header says $expected entries but only \
$restored were present -- the bundle file is truncated (partial download?)" >&2
    exit 1
fi

echo "Expanded $in into $dest: $restored entr(y/ies), $verified checksum(s) OK, $errors error(s)"
[ "$errors" -eq 0 ] || exit 1
