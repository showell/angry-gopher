#!/usr/bin/env bash
# Build every gesture module standalone, in addition to Main.
#
# Catches a class of bug that bit us during the Kinematics
# refactor: a gesture not currently wired into Main can
# silently bit-rot, because Main's import graph determines
# what `elm make src/Main.elm` actually compiles. Parked
# gestures (registered for a future study but not the
# active one) need their own type-check.
#
# Add new gestures to the GESTURES list below.

set -euo pipefail

cd "$(dirname "$0")"

GESTURES=(
  "src/Gesture/SingleCardDrop.elm"
  "src/Gesture/StackMerge.elm"
  "src/Gesture/InjectCard.elm"
  "src/Gesture/MoveStack.elm"
  "src/Gesture/IntegratedPlay.elm"
)

# Durable LynRummy model port — standalone type-check so the
# durable code never rots even when not wired into Main.
LYNRUMMY=(
  "src/LynRummy/Random.elm"
  "src/LynRummy/Card.elm"
  "src/LynRummy/StackType.elm"
  "src/LynRummy/CardStack.elm"
  "src/LynRummy/BoardGeometry.elm"
  "src/LynRummy/Referee.elm"
  "src/LynRummy/Tricks/Trick.elm"
  "src/LynRummy/Tricks/Helpers.elm"
  "src/LynRummy/Tricks/DirectPlay.elm"
  "src/LynRummy/Tricks/HandStacks.elm"
  "src/LynRummy/Tricks/SplitForSet.elm"
  "src/LynRummy/Tricks/PeelForRun.elm"
  "src/LynRummy/Tricks/RbSwap.elm"
  "src/LynRummy/Tricks/PairPeel.elm"
  "src/LynRummy/Tricks/LooseCardPlay.elm"
)

echo "==> Building Main"
npx --yes elm make src/Main.elm --output=elm.js >/dev/null

for g in "${GESTURES[@]}"; do
  echo "==> Type-checking $g standalone"
  npx --yes elm make "$g" --output=/dev/null >/dev/null
done

for m in "${LYNRUMMY[@]}"; do
  echo "==> Type-checking $m standalone"
  npx --yes elm make "$m" --output=/dev/null >/dev/null
done

echo "==> Running LynRummy tests"
# elm-test can't auto-discover elm when installed via npx; pass
# the compiler path explicitly.
ELM_BIN="$(npx --yes which elm 2>/dev/null || true)"
if [ -z "${ELM_BIN:-}" ]; then
  ELM_BIN="$(find ~/.npm/_npx -name elm -type f -path '*/bin/elm' 2>/dev/null | head -1)"
fi
npx --yes elm-test --compiler "$ELM_BIN" >/dev/null

echo "All gestures compile; LynRummy modules compile and tests pass."
