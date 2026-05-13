#!/usr/bin/env bash
# Expand a bundle produced by merge.sh back into individual files.
# Handles both text (===FILE:) and base64 (===FILE-B64:) sections.
# Usage: ./split.sh [bundle_file]   (default: bundle.txt)

set -e
cd "$(dirname "$0")"
in="${1:-bundle.txt}"

awk '
  function start(path) {
    n = split(path, parts, "/")
    if (n > 1) {
      dir = parts[1]
      for (i = 2; i < n; i++) dir = dir "/" parts[i]
      system("mkdir -p \"" dir "\"")
    }
    out = path
    printf "" > out
  }
  /^===FILE: .*===$/ {
    path = substr($0, 10, length($0) - 12)
    start(path)
    mode = "text"
    next
  }
  /^===FILE-B64: .*===$/ {
    path = substr($0, 14, length($0) - 16)
    start(path)
    mode = "b64"
    b64tmp = out ".b64.tmp"
    printf "" > b64tmp
    next
  }
  /^===END===$/ {
    if (mode == "b64") {
      close(b64tmp)
      system("base64 -d \"" b64tmp "\" > \"" out "\" && rm -f \"" b64tmp "\"")
    } else {
      close(out)
    }
    out = ""; mode = ""
    next
  }
  out {
    if (mode == "b64") print > b64tmp
    else print > out
  }
' "$in"

echo "Expanded $in"
