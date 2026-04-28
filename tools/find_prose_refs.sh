#!/bin/bash
# find_prose_refs.sh — find every cross-language prose
# reference to an Elm dotted module path.
#
# When renaming or moving an Elm module (e.g.
# Game.Card → Game.Rules.Card), call-site updates inside
# .elm files are mechanical. The friction is prose
# references in non-Elm files: Go template strings, Python
# docstrings, markdown docs, .claude sidecars, .dsl
# scenario files, etc. The renames-cross-into-prose
# principle says these prose mentions must be updated in
# the same commit as the source move.
#
# This script greps every non-Elm file under games/lynrummy/
# (plus angry-gopher/cmd/, tools/, top-level docs) for
# the given module path. Outputs file:line:context per hit.
#
# Surfaced as an IF in game_rules_lockdown phase 2b
# (2026-04-28) — the manual ad-hoc grep was costly enough
# to deserve a tool.
#
# Usage:
#     tools/find_prose_refs.sh Game.Card
#     tools/find_prose_refs.sh Game.Rules.StackType
#
# Output: file:line:context, sorted by file, suitable for
# review or pipe to xargs.

set -e

if [ $# -lt 1 ]; then
    echo "usage: $0 <Elm.Module.Path>" >&2
    echo "  e.g.: $0 Game.Card" >&2
    exit 1
fi

MODULE="$1"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

# Word-boundary-ish: the module path followed by a
# non-identifier char or end-of-line. This avoids
# matching Game.Card when the actual reference is
# Game.CardStack (different module).
PATTERN="\b${MODULE}\b"

echo "Searching for prose refs to '${MODULE}' in non-Elm files..." >&2
echo "" >&2

# Files to search:
# - Go source (.go)
# - Python (.py)
# - Markdown (.md)
# - Sidecars (.claude)
# - DSL scenarios (.dsl)
# - Plain text (.txt) — corpus baselines, etc.
# - JSON (.json) only if it might embed Elm strings
#
# Exclude: .elm files (those are the source-of-truth move
# target, handled by cmd/reorg or equivalent), build
# artifacts (elm-stuff, node_modules, .git).
grep -rn -E "$PATTERN" \
    --include="*.go" \
    --include="*.py" \
    --include="*.md" \
    --include="*.claude" \
    --include="*.dsl" \
    --include="*.txt" \
    --include="*.json" \
    --exclude-dir=.git \
    --exclude-dir=elm-stuff \
    --exclude-dir=node_modules \
    --exclude-dir=__pycache__ \
    . 2>/dev/null \
    | sort \
    || {
        echo "(no prose refs found)" >&2
    }
