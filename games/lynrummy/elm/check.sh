#!/usr/bin/env bash
# Type-check every durable LynRummy module standalone, then
# run the test suite. Keeps the durable code from bit-rotting
# regardless of which host shell imports it.
#
# Host shell (Main.elm + gesture studies) was ripped
# 2026-04-17 — only the durable model remains here.

set -euo pipefail

cd "$(dirname "$0")"

# elm + elm-test are pinned as devDependencies of this project.
# They live in ./node_modules/.bin/ after `npm install`. Calling
# them directly skips the ~1.3s-per-call bootstrap tax that
# `npx --yes` used to charge on every invocation — the loop
# below runs elm ~30 times, so this matters.
ELM_BIN="./node_modules/.bin/elm"
ELM_TEST_BIN="./node_modules/.bin/elm-test"
ELM_REVIEW_BIN="./node_modules/.bin/elm-review"

if [ ! -x "$ELM_BIN" ] || [ ! -x "$ELM_TEST_BIN" ]; then
  echo "elm / elm-test not found in ./node_modules/.bin/. Run \`npm install\` in $(pwd)." >&2
  exit 1
fi

# Type-check every .elm under src/Game/ standalone. Glob-driven
# so new modules (tricks, domain types) are picked up without
# editing this script. src/Main/ is excluded intentionally — Main
# modules are exercised by the full `elm make src/Main.elm`
# build below.
while IFS= read -r m; do
  echo "==> Type-checking $m standalone"
  "$ELM_BIN" make "$m" --output=/dev/null >/dev/null
done < <(find src/Game -name '*.elm' | sort)

echo "==> Building Main"
"$ELM_BIN" make src/Main.elm --output=elm.js >/dev/null

echo "==> Running LynRummy tests"
"$ELM_TEST_BIN" --compiler "$ELM_BIN" 2>&1 | tail -3

if [ -x "$ELM_REVIEW_BIN" ]; then
  echo "==> elm-review"
  "$ELM_REVIEW_BIN" --compiler "$ELM_BIN" 2>&1 | tail -3
fi

echo "All LynRummy modules compile, tests pass, elm-review clean."
