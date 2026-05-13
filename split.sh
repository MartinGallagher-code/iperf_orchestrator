#!/usr/bin/env bash
# Expand a bundle produced by merge.sh back into individual files.
# Usage: ./split.sh [bundle_file]   (default: bundle.txt)

set -e
cd "$(dirname "$0")"
in="${1:-bundle.txt}"

awk '
  /^===FILE: .*===$/ {
    path = substr($0, 10, length($0) - 12)
    n = split(path, parts, "/")
    if (n > 1) {
      dir = parts[1]
      for (i = 2; i < n; i++) dir = dir "/" parts[i]
      system("mkdir -p \"" dir "\"")
    }
    out = path
    printf "" > out
    next
  }
  /^===END===$/ { out = ""; next }
  out { print > out }
' "$in"

echo "Expanded $in"
