#!/usr/bin/env bash
# Merge all files in this directory (recursively) into one bundle.
# Text files are inlined verbatim; binary files are base64-encoded
# under a ===FILE-B64: marker.
# Usage: ./merge.sh [output_file]   (default: bundle.txt)

set -e
cd "$(dirname "$0")"
out="${1:-bundle.txt}"
: > "$out"

find . -type f ! -name "$(basename "$0")" ! -name "split.sh" ! -name "$out" \
    | sort | while read -r f; do
    rel="${f#./}"
    if grep -Iq . "$f"; then
        printf '===FILE: %s===\n' "$rel" >> "$out"
        cat "$f" >> "$out"
    else
        printf '===FILE-B64: %s===\n' "$rel" >> "$out"
        base64 "$f" >> "$out"
    fi
    printf '===END===\n' >> "$out"
done

echo "Wrote $(wc -l < "$out") lines to $out"
