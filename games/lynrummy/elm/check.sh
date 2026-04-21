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

if [ ! -x "$ELM_BIN" ] || [ ! -x "$ELM_TEST_BIN" ]; then
  echo "elm / elm-test not found in ./node_modules/.bin/. Run \`npm install\` in $(pwd)." >&2
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
