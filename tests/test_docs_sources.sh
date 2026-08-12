#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
#
# The documentation site has no prose of its own: every page pulls its
# body out of README.md (or CHANGELOG.md / PUBLISHING.md) with a MyST
# `include` directive keyed on <!-- docs:* --> markers. That keeps one
# copy of the text, but it also means an innocent README edit can
# quietly empty a page.
#
# Sphinx catches a *missing* marker (docutils errors when `start-after`
# finds no match), so these tests cover what it cannot: a section that
# grew no marker at all and would silently land on the wrong page, a
# marker nobody includes, and includes pointing at files that moved.
# They need no Sphinx install, so they run in the normal suite.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"

DOCS_DIR="$REPO_ROOT/docs"
README="$REPO_ROOT/README.md"

# ---- Marker coverage ------------------------------------------------------

test_every_readme_section_has_a_docs_marker() {
    # Ground truth: each level-2 heading must be immediately preceded by
    # a `<!-- docs:slug -->` line. Without one, a new section joins
    # whichever page owns the slice above it, which is never what the
    # author meant.
    local missing=()
    local prev="" line
    while IFS= read -r line; do
        if [[ "$line" == '## '* ]] && [[ "$prev" != '<!-- docs:'* ]]; then
            missing+=("$line")
        fi
        prev="$line"
    done < "$README"
    if [ "${#missing[@]}" -ne 0 ]; then
        echo "README sections with no <!-- docs:* --> marker above them:" >&2
        printf '    %s\n' "${missing[@]}" >&2
        echo "  Add a marker and include the slice from a page in docs/." >&2
        return 1
    fi
}

test_every_marker_is_included_by_a_docs_page() {
    # A marker nobody references means a README section reaches no page.
    # `docs:end` is the shared slice terminator and is referenced by
    # `end-before`, so it is checked separately below.
    # A marker is a line that is nothing but the comment. Prose may
    # mention the syntax inline (the Documentation section does); that
    # is not a marker and must not be counted as one.
    local slugs includes missing=()
    slugs=$(grep -oE '^<!-- docs:[a-z-]+ -->$' "$README" | sort -u | grep -v 'docs:end')
    includes=$(grep -rhoE '^:start-after: <!-- docs:[a-z-]+ -->' "$DOCS_DIR"/*.md | sort -u)
    local slug
    while IFS= read -r slug; do
        [ -n "$slug" ] || continue
        echo "$includes" | grep -qF "$slug" || missing+=("$slug")
    done <<< "$slugs"
    if [ "${#missing[@]}" -ne 0 ]; then
        echo "markers in README.md that no docs page includes:" >&2
        printf '    %s\n' "${missing[@]}" >&2
        return 1
    fi
}

test_every_included_marker_exists_in_the_readme() {
    # The inverse of the test above: an include that names a marker the
    # README no longer has. Sphinx does catch this (docutils errors when
    # `start-after` matches nothing), but only in the docs build; catch
    # it here so a README edit fails in the normal suite too.
    local missing=() slug
    while IFS= read -r slug; do
        [ -n "$slug" ] || continue
        grep -qF "$slug" "$README" || missing+=("$slug")
    done < <(grep -rhoE '<!-- docs:[a-z-]+ -->' "$DOCS_DIR"/*.md | sort -u)
    if [ "${#missing[@]}" -ne 0 ]; then
        echo "docs pages include markers that README.md does not contain:" >&2
        printf '    %s\n' "${missing[@]}" >&2
        return 1
    fi
}

test_docs_end_marker_terminates_every_slice() {
    # Every slice must stop before the `---` rule that closes its
    # section, or the page ends on a transition and docutils refuses to
    # build it. The one exception is the README's final section, which
    # runs to end-of-file and needs no terminator.
    local last_slug
    last_slug=$(grep -oE '^<!-- docs:[a-z-]+ -->$' "$README" \
        | grep -v 'docs:end' | tail -n 1)
    local bad=()
    local page
    for page in "$DOCS_DIR"/*.md; do
        # Walk each ```{include} block and pair its options up.
        local in_block=0 start="" end="" line
        while IFS= read -r line; do
            case "$line" in
                '```{include}'*) in_block=1; start=""; end="" ;;
                ':start-after:'*) [ "$in_block" = 1 ] && start="${line#:start-after: }" ;;
                ':end-before:'*) [ "$in_block" = 1 ] && end="${line#:end-before: }" ;;
                '```')
                    if [ "$in_block" = 1 ]; then
                        if [ -n "$start" ] && [ "$start" != "$last_slug" ] \
                           && [ "$end" != "<!-- docs:end -->" ]; then
                            bad+=("$(basename "$page"): slice from $start is not terminated by <!-- docs:end -->")
                        fi
                        in_block=0
                    fi
                    ;;
            esac
        done < "$page"
    done
    if [ "${#bad[@]}" -ne 0 ]; then
        printf '    %s\n' "${bad[@]}" >&2
        return 1
    fi
}

# ---- Include targets ------------------------------------------------------

test_every_include_target_exists() {
    local missing=() target
    while IFS= read -r target; do
        [ -n "$target" ] || continue
        [ -f "$DOCS_DIR/$target" ] || missing+=("$target")
    done < <(grep -rhoE '^```\{include\} [^ ]+' "$DOCS_DIR"/*.md | awk '{print $2}' | sort -u)
    if [ "${#missing[@]}" -ne 0 ]; then
        echo "docs include directives pointing at files that do not exist:" >&2
        printf '    %s\n' "${missing[@]}" >&2
        return 1
    fi
}

test_every_docs_page_is_in_the_toctree() {
    # A page missing from the toctree still builds, but is reachable
    # only by URL and Sphinx warns -- which fails the Read the Docs
    # build, since fail_on_warning is on.
    local missing=() page name
    for page in "$DOCS_DIR"/*.md; do
        name="$(basename "$page" .md)"
        [ "$name" = "index" ] && continue
        grep -qE "^$name\$" <(sed -n '/^```{toctree}/,/^```$/p' "$DOCS_DIR/index.md") \
            || missing+=("$name")
    done
    if [ "${#missing[@]}" -ne 0 ]; then
        echo "docs pages missing from the index.md toctree:" >&2
        printf '    %s\n' "${missing[@]}" >&2
        return 1
    fi
}

# ---- Build configuration --------------------------------------------------

test_readthedocs_config_points_at_the_sphinx_conf() {
    local cfg="$REPO_ROOT/.readthedocs.yaml"
    [ -f "$cfg" ] || { echo "missing .readthedocs.yaml" >&2; return 1; }
    grep -q 'configuration: docs/conf.py' "$cfg" || {
        echo ".readthedocs.yaml should point sphinx.configuration at docs/conf.py" >&2
        return 1
    }
    [ -f "$DOCS_DIR/conf.py" ] || { echo "missing docs/conf.py" >&2; return 1; }
    grep -q 'requirements: docs/requirements.txt' "$cfg" || {
        echo ".readthedocs.yaml should install docs/requirements.txt" >&2
        return 1
    }
    [ -f "$DOCS_DIR/requirements.txt" ] || {
        echo "missing docs/requirements.txt" >&2
        return 1
    }
}

test_docs_version_tracks_the_package_version() {
    # conf.py scrapes __version__ with a regex rather than importing the
    # package (importing would drag numpy/matplotlib into the docs
    # build). If the assignment is ever reformatted, the scrape breaks
    # and the site silently renders with no version -- so assert the
    # exact shape the regex expects.
    grep -qE '^__version__ = "[0-9]+\.[0-9]+\.[0-9]+"$' \
        "$REPO_ROOT/iperf_orchestrator/__init__.py" || {
        echo "__init__.py no longer matches the pattern docs/conf.py scrapes" >&2
        return 1
    }
}

run_test test_every_readme_section_has_a_docs_marker
run_test test_every_marker_is_included_by_a_docs_page
run_test test_every_included_marker_exists_in_the_readme
run_test test_docs_end_marker_terminates_every_slice
run_test test_every_include_target_exists
run_test test_every_docs_page_is_in_the_toctree
run_test test_readthedocs_config_points_at_the_sphinx_conf
run_test test_docs_version_tracks_the_package_version

report_tests
