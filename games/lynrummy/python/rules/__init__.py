"""
rules/ — the Class-1/2 truth layer for the Python LynRummy
agent.

Mirrors `games/lynrummy/elm/src/Game/Rules/`. Pure game
rules and primitives that are battle-tested and not expected
to change: card model + classification + rule predicates.

Re-exports the public surface so callers can write
`from rules import classify, neighbors, ...` without caring
which sub-module a symbol lives in. Sub-module layout
matches Elm's:

  - `rules.card` — `Game.Rules.Card`: card model, label
    parser/renderers, suit color.
  - `rules.stack_type` — `Game.Rules.StackType`: value-cycle
    `successor`, classifier `classify`, rule predicates
    `is_partial_ok` / `neighbors`.

Verb-eligibility predicates (`can_peel` etc.) are NOT here
— those are agent strategy, not rules. They live in
`cards.py`. (Elm's equivalents live in
`Game.Agent.Enumerator` after the rule predicates split
out on 2026-04-28; the now-removed `Game.Agent.Cards`
module previously hosted both.)
"""

from rules.card import (
    RANKS,
    SUITS,
    RED,
    card,
    label,
    card_label,
    color,
)
from rules.stack_type import (
    successor,
    classify,
    is_partial_ok,
    neighbors,
)

__all__ = [
    "RANKS",
    "SUITS",
    "RED",
    "card",
    "label",
    "card_label",
    "color",
    "successor",
    "classify",
    "is_partial_ok",
    "neighbors",
]
