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

# Resolve the elm binary once. Calling `npx --yes elm ...` in
# a 30-iteration loop used to dominate this script (≈1.28s of
# npx bootstrap per call, ≈37s of pure overhead). Direct
# invocation of the cached binary is ≈0.05s per call.
ELM_BIN="$(npx --yes which elm 2>/dev/null || true)"
if [ -z "${ELM_BIN:-}" ]; then
  ELM_BIN="$(find ~/.npm/_npx -name elm -type f -path '*/bin/elm' 2>/dev/null | head -1)"
fi
if [ -z "${ELM_BIN:-}" ] || [ ! -x "$ELM_BIN" ]; then
  echo "Could not locate an elm binary via npx or ~/.npm/_npx." >&2
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
npx --yes elm-test --compiler "$ELM_BIN" >/dev/null

echo "All LynRummy modules compile and tests pass."
