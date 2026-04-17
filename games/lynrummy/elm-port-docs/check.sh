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

echo "All LynRummy modules compile and tests pass."
