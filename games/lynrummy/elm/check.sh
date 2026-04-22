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
  "src/Game/Random.elm"
  "src/Game/Card.elm"
  "src/Game/StackType.elm"
  "src/Game/CardStack.elm"
  "src/Game/BoardGeometry.elm"
  "src/Game/Referee.elm"
  "src/Game/Score.elm"
  "src/Game/BoardPhysics.elm"
  "src/Game/PlayerTurn.elm"
  "src/Game/BoardActions.elm"
  "src/Game/PlaceStack.elm"
  "src/Game/Dealer.elm"
  "src/Game/GestureArbitration.elm"
  "src/Game/Hand.elm"
  "src/Game/Game.elm"
  "src/Game/Reducer.elm"
  "src/Game/View.elm"
  "src/Game/WingOracle.elm"
  "src/Game/WireAction.elm"
  "src/Game/Strategy/Trick.elm"
  "src/Game/Strategy/Helpers.elm"
  "src/Game/Strategy/DirectPlay.elm"
  "src/Game/Strategy/HandStacks.elm"
  "src/Game/Strategy/SplitForSet.elm"
  "src/Game/Strategy/PeelForRun.elm"
  "src/Game/Strategy/RbSwap.elm"
  "src/Game/Strategy/PairPeel.elm"
  "src/Game/Strategy/LooseCardPlay.elm"
  "src/Game/Strategy/Hint.elm"
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
