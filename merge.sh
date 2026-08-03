#!/usr/bin/env bash
# merge.sh -- bundle a directory tree into a single text file.
#
# Usage: merge.sh [-n PARTS] [OUTPUT] [SOURCE_DIR]
#   -n, --parts PARTS  split into PARTS bundles (default: 1)
#   OUTPUT      bundle file to write   (default: bundle.txt)
#   SOURCE_DIR  directory to bundle    (default: current directory)
#
# Companion of split.sh, which expands the bundle again.
#
# With -n, the tree is spread over PARTS files named after OUTPUT --
# bundle.part1of2.txt, bundle.part2of2.txt -- for transports that cap the
# size of a single file.  Each part is a complete, independently valid
# bundle with its own header and checksums, so split.sh expands them one
# at a time (in any order) into the same destination:
#
#   ./merge.sh -n 2                      # write the two parts
#   ./split.sh bundle.part1of2.txt out/  # expand either part first
#   ./split.sh bundle.part2of2.txt out/  # ...then the other
#
# Entries are never cut in half; parts are balanced by byte size, so a
# single file larger than the target share still lands whole in one part.
#
# Format (v2) -- one section per entry:
#   ===FILE: rel/path===          text file, inlined verbatim
#   ===FILE-B64: rel/path===      binary (or marker-colliding) file, base64
#   ===DIR: rel/path===           empty directory
#   ===LINK: rel/path===          symlink; the target is the section body
#   ===META: mode=644 sha256=... nonl=1===
#                                 optional, directly after FILE/FILE-B64:
#                                 permissions, checksum, and a flag for files
#                                 with no trailing newline
#   ===END===                     closes every section
#
# Robustness properties:
#   * filenames with spaces/quotes/globs are safe (NUL-separated find);
#     filenames containing newlines or control characters are skipped
#     with a warning -- they cannot be represented in a line-based format
#   * a text file that itself contains "===...===" marker lines is stored
#     base64-encoded so it can never corrupt the bundle
#   * text files without a trailing newline round-trip exactly (nonl=1)
#   * empty files stay text (not base64), empty dirs and symlinks survive
#   * the output file is written atomically (tmp + rename) and never
#     bundles itself, even mid-write
#   * per-file sha256 recorded when a checksum tool is available, so
#     split.sh can verify integrity
#   * deterministic entry order (LC_ALL=C sort) -- same tree, same bundle

set -euo pipefail
export LC_ALL=C

usage() {
    sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

parts=1
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)   usage 0 ;;
        -n|--parts)  [ $# -ge 2 ] || { echo "merge.sh: $1 needs a value" >&2; exit 1; }
                     parts="$2"; shift 2 ;;
        --parts=*)   parts="${1#*=}"; shift ;;
        -n*)         parts="${1#-n}"; shift ;;
        --)          shift; break ;;
        -*)          echo "merge.sh: unknown option: $1" >&2; usage 1 ;;
        *)           break ;;
    esac
done

case "$parts" in
    ''|*[!0-9]*) echo "merge.sh: --parts wants a positive integer, got: $parts" >&2; exit 1 ;;
esac
[ "$parts" -ge 1 ] || { echo "merge.sh: --parts must be >= 1" >&2; exit 1; }

out="${1:-bundle.txt}"
src="${2:-.}"

[ -d "$src" ] || { echo "merge.sh: source directory not found: $src" >&2; exit 1; }

# Absolute paths for self-exclusion (output, its tempfile, and these scripts).
# The directory half is resolved with cd/pwd rather than glued onto $PWD, so
# that invocation forms like "./merge.sh" normalise to the same string the
# find loop builds ("$src_abs/$rel").  Without this the "./" survives, no
# comparison ever matches, and merge.sh bundles itself.
abspath() {
    local dir base
    dir=$(dirname -- "$1")
    base=$(basename -- "$1")
    dir=$(cd "$dir" 2>/dev/null && pwd) || dir="$PWD"
    printf '%s/%s\n' "$dir" "$base"
}
out_abs=$(abspath "$out")
tmp_abs="$out_abs.tmp.$$"
script_abs=$(abspath "$0")
split_abs="$(dirname "$script_abs")/split.sh"
src_abs=$(cd "$src" && pwd)

# "bundle.txt" + part 1 of 2 -> "bundle.part1of2.txt".  The extension is
# kept last on purpose: transports that judge a file by its suffix should
# still see .txt.
case "$out" in
    */.*|.*)  out_base="$out"; out_ext="" ;;      # dotfile, no extension
    *.*)      out_base="${out%.*}"; out_ext=".${out##*.}" ;;
    *)        out_base="$out"; out_ext="" ;;
esac
part_name() {  # $1=index
    printf '%s.part%dof%d%s\n' "$out_base" "$1" "$parts" "$out_ext"
}
part_prefix_abs=$(abspath "$out_base")

# Everything the bundle must never contain: the output(s), the tempfiles,
# and the two scripts.  Part files are listed too, so re-running merge.sh
# in a directory that already holds a previous run's parts does not bundle
# them into the new one.
excludes=("$out_abs" "$tmp_abs" "$script_abs" "$split_abs")
if [ "$parts" -gt 1 ]; then
    i=1
    while [ "$i" -le "$parts" ]; do
        excludes+=("$(abspath "$(part_name "$i")")")
        i=$((i + 1))
    done
fi
is_excluded() {
    local e
    for e in "${excludes[@]}"; do
        [ "$1" = "$e" ] && return 0
    done
    # Also catch parts left over from an earlier run with a different -n:
    # those names are not in the list above, but bundling one bundle into
    # the next is never what anyone wants.
    case "$1" in
        "$part_prefix_abs".part*of*"$out_ext") return 0 ;;
    esac
    return 1
}

# Checksum tool (optional -- bundles still work without one).
if command -v sha256sum >/dev/null 2>&1; then
    sha() { sha256sum <"$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
    sha() { shasum -a 256 <"$1" | awk '{print $1}'; }
else
    sha() { :; }
fi

# Permission bits, portable across GNU and BSD stat.
mode_of() {
    stat -c '%a' "$1" 2>/dev/null && return
    stat -f '%Lp' "$1" 2>/dev/null && return
    if [ -x "$1" ]; then echo 755; else echo 644; fi
}

files=0 b64s=0 dirs=0 links=0 skipped=0

warn_skip() {
    printf 'merge.sh: skipping (%s): %s\n' "$2" "$1" >&2
    skipped=$((skipped + 1))
}

# True if the file is non-empty and its last byte is not a newline.
# (od instead of command substitution on the raw byte: a trailing NUL in a
# binary would otherwise make bash warn about ignored null bytes.)
lacks_final_newline() {
    [ -s "$1" ] || return 1
    [ "$(tail -c 1 "$1" | od -An -tx1 | tr -d ' \n')" != "0a" ]
}

emit_meta() {  # $1=file
    local mode sum extra=""
    mode=$(mode_of "$1")
    sum=$(sha "$1" || true)
    lacks_final_newline "$1" && extra=" nonl=1"
    printf '===META: mode=%s%s%s===\n' \
        "$mode" "${sum:+ sha256=$sum}" "$extra"
}

# Does this file need base64?  Binary content, or lines that would collide
# with our markers.  Empty files are plain text.
needs_b64() {  # $1=file
    [ -s "$1" ] || return 1
    grep -Iq . "$1" 2>/dev/null || return 0
    grep -qE '^===(FILE|FILE-B64|DIR|LINK|META|END)' "$1" 2>/dev/null && return 0
    return 1
}

sort_z() {
    if printf 'b\0a\0' | sort -z >/dev/null 2>&1; then sort -z; else cat; fi
}

body_abs="$tmp_abs.body"
excludes+=("$body_abs")
trap 'rm -f "$tmp_abs" "$body_abs"' EXIT

# The body is written first so the entry count is known, then the final
# bundle is assembled with the count in the header.  split.sh compares the
# header count against what it restored, which catches a bundle truncated
# exactly at a section boundary -- a cut that would otherwise parse cleanly.
{
    while IFS= read -r -d '' f; do
        rel="${f#"$src"/}"
        [ "$rel" = "$f" ] && continue          # the source dir itself
        f_abs="$src_abs/$rel"
        # The body tempfile is in the exclude list too: find runs concurrently
        # with the loop that writes it, so bundling into the tree being scanned
        # would otherwise inline the growing file into itself and never
        # terminate.
        is_excluded "$f_abs" && continue

        case "$rel" in
            *[$'\x01'-$'\x1f']*)
                warn_skip "$rel" "control character in name"; continue ;;
        esac

        if [ -L "$f" ]; then
            target=$(readlink "$f") || { warn_skip "$rel" "unreadable link"; continue; }
            case "$target" in
                *$'\n'*) warn_skip "$rel" "newline in link target"; continue ;;
            esac
            printf '===LINK: %s===\n%s\n===END===\n' "$rel" "$target"
            links=$((links + 1))
        elif [ -d "$f" ]; then
            printf '===DIR: %s===\n===END===\n' "$rel"
            dirs=$((dirs + 1))
        elif [ -f "$f" ]; then
            if [ ! -r "$f" ]; then warn_skip "$rel" "unreadable"; continue; fi
            if needs_b64 "$f"; then
                printf '===FILE-B64: %s===\n' "$rel"
                emit_meta "$f"
                base64 <"$f"
                printf '===END===\n'
                b64s=$((b64s + 1))
            else
                printf '===FILE: %s===\n' "$rel"
                emit_meta "$f"
                cat "$f"
                # Keep the closing marker on its own line even when the file
                # does not end with a newline; nonl=1 lets split.sh undo this.
                lacks_final_newline "$f" && printf '\n'
                printf '===END===\n'
            fi
            files=$((files + 1))
        fi
    done < <(
        find "$src" -name .git -prune -o \
            \( -type f -o -type l -o \( -type d -empty \) \) -print0 \
        | sort_z
    )
} > "$body_abs"

entries=$((files + dirs + links))

if [ "$parts" -le 1 ]; then
    {
        printf '# bundle format v2 (merge.sh) -- expand with split.sh\n'
        printf '# bundle entries: %s\n' "$entries"
        cat "$body_abs"
    } > "$tmp_abs"
    rm -f "$body_abs"

    mv "$tmp_abs" "$out_abs"
    trap - EXIT

    total_lines=$(($(wc -l < "$out_abs")))
    echo "Wrote $out: $files file(s) ($b64s base64), $dirs empty dir(s), \
$links symlink(s), $skipped skipped, $total_lines lines"
    exit 0
fi

# --- multi-part output ---------------------------------------------------
# Cut the body on ===END=== boundaries so no entry is ever split across two
# files, balancing parts by byte size.  Each part then gets its own header,
# which is what makes it independently expandable.
split_dir="$tmp_abs.parts"
mkdir -p "$split_dir"
trap 'rm -f "$tmp_abs" "$body_abs"; rm -rf "$split_dir"' EXIT

body_bytes=$(wc -c < "$body_abs")
awk -v parts="$parts" -v total="$body_bytes" -v dir="$split_dir" '
BEGIN { part = 1; target = total / parts; cur = 0; n = 0; buf = "" }
{
    buf = buf $0 "\n"
    len += length($0) + 1
}
/^===END===$/ {
    printf "%s", buf > (dir "/body" part)
    cur += len; n++
    buf = ""; len = 0
    # Move on once this part has taken its share, keeping at least one
    # entry for every remaining part.
    if (part < parts && cur >= target * part) {
        close(dir "/body" part)
        print n > (dir "/count" part)
        close(dir "/count" part)
        part++; n = 0
    }
}
END {
    if (buf != "") printf "%s", buf > (dir "/body" part)
    close(dir "/body" part)
    print n > (dir "/count" part)
    close(dir "/count" part)
    # Parts that never received an entry still need to exist as empty
    # bundles rather than silently vanishing from the numbering.
    for (i = part + 1; i <= parts; i++) {
        printf "" > (dir "/body" i)
        close(dir "/body" i)
        print 0 > (dir "/count" i)
        close(dir "/count" i)
    }
}
' "$body_abs"
rm -f "$body_abs"

written=0
i=1
while [ "$i" -le "$parts" ]; do
    pname=$(part_name "$i")
    pabs=$(abspath "$pname")
    pcount=$(cat "$split_dir/count$i")
    {
        printf '# bundle format v2 (merge.sh) -- expand with split.sh\n'
        printf '# bundle part %d of %d\n' "$i" "$parts"
        printf '# bundle entries: %s\n' "$pcount"
        cat "$split_dir/body$i"
    } > "$pabs.tmp.$$"
    mv "$pabs.tmp.$$" "$pabs"
    written=$((written + pcount))
    echo "  $pname: $pcount entr(y/ies), $(wc -c < "$pabs") bytes, \
$(wc -l < "$pabs") lines"
    i=$((i + 1))
done

rm -rf "$split_dir"
trap - EXIT

if [ "$written" -ne "$entries" ]; then
    echo "merge.sh: internal error: split $written of $entries entries" >&2
    exit 1
fi

echo "Wrote $parts part(s) of $out: $files file(s) ($b64s base64), \
$dirs empty dir(s), $links symlink(s), $skipped skipped, $entries entries total"
