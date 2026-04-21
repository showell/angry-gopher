#!/usr/bin/env bash
# Type-check every durable LynRummy module standalone, then
# run the test suite. Keeps the durable code from bit-rotting
# regardless of which host shell imports it.
#
# Host shell (Main.elm + gesture studies) was ripped
# 2026-04-17 — only the durable model remains here; the
# playable game will be built fresh on top of these modules.

set -euo pipefail

cd "$(dirname "$0")"

# Resolve cached binaries once. `npx --yes <cmd>` pays ≈1.3s of
# package-resolution overhead EVERY invocation, even when cached;
# direct calls are ≈0.05s for elm and ≈0.06s for elm-test. The
# loop below runs elm ~30 times, so this matters.
ELM_BIN="$(find ~/.npm/_npx -name elm -type f -path '*/bin/elm' 2>/dev/null | head -1)"
if [ -z "${ELM_BIN:-}" ]; then
  # Fallback: materialize the cache via npx. Costs ~1.3s so we
  # avoid it on every run — the `find` above is instant and
  # works as long as the cache has ever been warmed.
  ELM_BIN="$(npx --yes which elm 2>/dev/null || true)"
fi
if [ -z "${ELM_BIN:-}" ] || [ ! -x "$ELM_BIN" ]; then
  echo "Could not locate an elm binary under ~/.npm/_npx or via npx." >&2
  exit 1
fi

ELM_TEST_BIN="$(find ~/.npm/_npx -name elm-test -type f -path '*/bin/elm-test' 2>/dev/null | head -1)"
if [ -z "${ELM_TEST_BIN:-}" ] || [ ! -x "$ELM_TEST_BIN" ]; then
  echo "Could not locate an elm-test binary under ~/.npm/_npx." >&2
  exit 1
fi

LYNRUMMY=(
  "src/LynRummy/Random.elm"
  "src/LynRummy/Card.elm"
  "src/LynRummy/StackType.elm"
  "src/LynRummy/CardStack.elm"
  "src/LynRummy/BoardGeometry.elm"
  "src/LynRummy/Referee.elm"
  "src/LynRummy/Score.elm"
  "src/LynRummy/BoardPhysics.elm"
  "src/LynRummy/PlayerTurn.elm"
  "src/LynRummy/BoardActions.elm"
  "src/LynRummy/PlaceStack.elm"
  "src/LynRummy/Dealer.elm"
  "src/LynRummy/GestureArbitration.elm"
  "src/LynRummy/Hand.elm"
  "src/LynRummy/Game.elm"
  "src/LynRummy/Reducer.elm"
  "src/LynRummy/View.elm"
  "src/LynRummy/WingOracle.elm"
  "src/LynRummy/WireAction.elm"
  "src/LynRummy/Tricks/Trick.elm"
  "src/LynRummy/Tricks/Helpers.elm"
  "src/LynRummy/Tricks/DirectPlay.elm"
  "src/LynRummy/Tricks/HandStacks.elm"
  "src/LynRummy/Tricks/SplitForSet.elm"
  "src/LynRummy/Tricks/PeelForRun.elm"
  "src/LynRummy/Tricks/RbSwap.elm"
  "src/LynRummy/Tricks/PairPeel.elm"
  "src/LynRummy/Tricks/LooseCardPlay.elm"
  "src/LynRummy/Tricks/Hint.elm"
)

for m in "${LYNRUMMY[@]}"; do
  echo "==> Type-checking $m standalone"
  "$ELM_BIN" make "$m" --output=/dev/null >/dev/null
done

echo "==> Building Main"
"$ELM_BIN" make src/Main.elm --output=elm.js >/dev/null

echo "==> Running LynRummy tests"
"$ELM_TEST_BIN" --compiler "$ELM_BIN" >/dev/null

echo "All LynRummy modules compile and tests pass."
