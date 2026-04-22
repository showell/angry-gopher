#!/usr/bin/env bash
# BOARD_LAB Elm build + standalone type-check. Uses the sibling
# LynRummy Elm project's pinned elm binary (no separate npm
# install here — both apps pin the same elm version, so the
# binary is shared).

set -euo pipefail

cd "$(dirname "$0")"

ELM_BIN="../../elm/node_modules/.bin/elm"

if [ ! -x "$ELM_BIN" ]; then
  echo "elm not found at $ELM_BIN. Run \`npm install\` in games/lynrummy/elm." >&2
  exit 1
fi

echo "==> Building BOARD_LAB Main"
"$ELM_BIN" make src/Main.elm --output=elm.js >/dev/null

echo "BOARD_LAB compiled."
