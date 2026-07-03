#!/usr/bin/env bash
# Type-check every durable LynRummy module standalone, then build
# both entry points (Game.elm → elm.js, Puzzle.elm → puzzle.js), then
# run the test suite and elm-review.

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

# Type-check every .elm under src/Game/ and src/Puzzle/ standalone.
# Glob-driven so new modules (tricks, domain types) are picked up
# without editing this script. The entry-point files src/Game.elm and
# src/Puzzle.elm sit beside those dirs (not inside them), so they're
# not globbed here — the full `elm make` builds below exercise them.
echo "==> Type-checking standalone"
t0=$SECONDS
n=0
slow_lines=""
while IFS= read -r m; do
  m_t0=$SECONDS
  "$ELM_BIN" make "$m" --output=/dev/null >/dev/null
  m_dt=$((SECONDS - m_t0))
  n=$((n + 1))
  if [ "$m_dt" -ge 2 ]; then
    slow_lines+="    [standalone] ${m_dt}s  ${m}"$'\n'
  fi
done < <(find src/Game src/Puzzle -name '*.elm' | sort)
echo "    [phase] standalone (${n} modules): $((SECONDS - t0))s"
if [ -n "$slow_lines" ]; then
  printf '%s' "$slow_lines"
fi

echo "==> Building Game"
t0=$SECONDS
"$ELM_BIN" make src/Game.elm --output=elm.js >/dev/null
echo "    [phase] build-game: $((SECONDS - t0))s"

echo "==> Building Puzzle"
t0=$SECONDS
"$ELM_BIN" make src/Puzzle.elm --output=puzzle.js >/dev/null
echo "    [phase] build-puzzle: $((SECONDS - t0))s"

echo "==> Running LynRummy tests"
t0=$SECONDS
"$ELM_TEST_BIN" --compiler "$ELM_BIN" 2>&1 | tail -3
echo "    [phase] elm-test: $((SECONDS - t0))s"

if [ -x "$ELM_REVIEW_BIN" ]; then
  echo "==> elm-review"
  t0=$SECONDS
  "$ELM_REVIEW_BIN" --compiler "$ELM_BIN" 2>&1
  echo "    [phase] elm-review: $((SECONDS - t0))s"
fi

echo "All LynRummy modules compile, tests pass, elm-review clean."
