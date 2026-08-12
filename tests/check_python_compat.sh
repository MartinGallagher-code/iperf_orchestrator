#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
#
# Python version-compatibility guard.
#
# The orchestrator is bash, but it shells out to Python for the analysis
# steps, and that Python lives in `<<'PYEOF'` heredocs inside
# iperf_orchestrator.sh where no linter would normally look. This script
# extracts every such block (plus the pip-wrapper modules) and byte-compiles
# them, so a construct newer than our declared `requires-python` floor gets
# caught rather than blowing up on a user's older interpreter.
#
# Usage:
#   tests/check_python_compat.sh              # compile with $PYTHON_BIN (default python3)
#   PYTHON_BIN=python3.6 tests/check_python_compat.sh
#   tests/check_python_compat.sh --extract-to DIR   # just dump the blocks
#
# Compiling under the *oldest* supported interpreter catches syntax-level
# regressions (a `from __future__ import annotations`, a walrus). It does not
# catch stdlib functions added in a later version -- `vermin --target=3.6` in
# CI covers that axis.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ORCH="$REPO_ROOT/iperf_orchestrator/iperf_orchestrator.sh"
PYTHON_BIN="${PYTHON_BIN:-python3}"

extract_to=""
if [ "${1:-}" = "--extract-to" ]; then
    extract_to="${2:?--extract-to needs a directory}"
    mkdir -p "$extract_to"
fi

if [ -n "$extract_to" ]; then
    workdir="$extract_to"
    cleanup() { :; }
else
    workdir="$(mktemp -d)"
    cleanup() { rm -rf "$workdir"; }
fi
trap cleanup EXIT

[ -f "$ORCH" ] || { echo "ERROR: $ORCH not found" >&2; exit 2; }

# Split out each heredoc body into its own file. The block name is taken from
# the enclosing `cmd_*`/function line most recently seen, so failures point at
# a subcommand rather than an anonymous index.
awk -v out="$workdir" '
    /^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{/ {
        fn = $0; sub(/\(\).*/, "", fn)
    }
    /<<'"'"'PYEOF'"'"'/ {
        n++
        name = (fn != "" ? fn : "block")
        file = out "/" n "_" name ".py"
        collecting = 1
        next
    }
    /^PYEOF$/ { collecting = 0; file = ""; next }
    collecting { print > file }
' "$ORCH"

shopt -s nullglob
blocks=("$workdir"/*.py)
shopt -u nullglob

if [ ${#blocks[@]} -eq 0 ]; then
    echo "ERROR: no PYEOF blocks extracted from $ORCH -- extractor is broken" >&2
    exit 2
fi

if [ -n "$extract_to" ]; then
    printf '%s\n' "${blocks[@]}"
    exit 0
fi

pyver="$("$PYTHON_BIN" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])')"
echo "python-compat check: $PYTHON_BIN ($pyver)"
echo "  embedded blocks: ${#blocks[@]}"

fail=0
for f in "${blocks[@]}" "$REPO_ROOT"/iperf_orchestrator/*.py; do
    if "$PYTHON_BIN" -m py_compile "$f" 2>/tmp/pycompat.$$ ; then
        echo "  OK       $(basename "$f")"
    else
        echo "  FAIL     $(basename "$f")"
        sed 's/^/           /' /tmp/pycompat.$$ >&2
        fail=$((fail + 1))
    fi
    rm -f /tmp/pycompat.$$
done

# py_compile leaves __pycache__ next to the package sources; don't dirty the tree.
rm -rf "$REPO_ROOT/iperf_orchestrator/__pycache__"

if [ "$fail" -ne 0 ]; then
    echo "python-compat: $fail file(s) failed to compile under $pyver" >&2
    exit 1
fi
echo "python-compat: all files compile under $pyver"
