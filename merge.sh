#!/usr/bin/env bash
# Merge all files in this directory (recursively) into one bundle.
# Usage: ./merge.sh [output_file]   (default: bundle.txt)

set -e
cd "$(dirname "$0")"
out="${1:-bundle.txt}"
: > "$out"

find . -type f ! -name "$(basename "$0")" ! -name "split.sh" ! -name "$out" \
    | sort | while read -r f; do
    printf '===FILE: %s===\n' "${f#./}" >> "$out"
    cat "$f" >> "$out"
    printf '===END===\n' >> "$out"
done

echo "Wrote $(wc -l < "$out") lines to $out"
