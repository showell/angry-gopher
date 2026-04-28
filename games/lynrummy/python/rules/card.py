"""
rules/card.py — Card primitives.

The Python equivalent of `Game.Rules.Card.elm`. Holds the
deck-agnostic card model: rank/suit alphabets, the (value,
suit, deck) tuple shape, label parser/renderers, and the
suit-color helper.

Class-1/2: locked-down domain primitives. The whole BFS
planner sits on these; they're not expected to change.
"""

# --- Card + board model ---

RANKS = "A23456789TJQK"
SUITS = "CDSH"           # Clubs Diamonds Spades Hearts
RED = {1, 3}             # Diamonds, Hearts


def card(label, deck=0):
    """'5H' → (5, 3, 0). 'TC:1' → (10, 0, 1)."""
    if ":" in label:
        label, d = label.split(":")
        deck = int(d)
    return (RANKS.index(label[0]) + 1,
            SUITS.index(label[1]),
            deck)


def label(c):
    v, s, _ = c
    return RANKS[v - 1] + SUITS[s]


def card_label(c):
    """Label that includes deck suffix when non-zero. Used
    in DSL output where two cards of the same value+suit
    can co-exist (one per deck) and need to be told apart."""
    v, s, d = c
    base = RANKS[v - 1] + SUITS[s]
    return f"{base}:{d}" if d else base


def color(s):
    return "red" if s in RED else "black"
