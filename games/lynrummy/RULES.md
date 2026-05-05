# Lyn Rummy — rules

A simple reference. The on-screen game and the kitchen-table
game are essentially the same game; what differs is UI
mechanics (how a card moves from hand to board, how stacks
rearrange, how undo works). The rules below describe both.

## Setup

- **Two decks**, 104 cards total — every (value, suit) pair
  appears twice. The two-deck shape is integral; cards are
  identified by `(value, suit, origin_deck)`.
- **Two players.**
- **15-card starting hand** per player (the convention this
  codebase uses; kitchen-table rules vary on opening hand
  size).
- A shared **board** sits between the two hands. All melding
  happens on the board.

## What can sit on the board

A "stack" is a contiguous group of cards. At the moment a
player ends their turn, **every stack on the board must be a
length-3+ legal meld** of one of three kinds:

- **Set** — same value, distinct suits. Same `(value, suit)`
  cannot appear twice in a set even though two decks are in
  play. Max length is 4 (one of each suit).
- **Pure run** — 3+ consecutive values, same suit.
- **Rb run** — 3+ consecutive values, alternating colors
  (red and black).

The K → A → 2 wrap is integral. `[Q♠ K♠ A♠]` is a valid
pure run. So is `[K♠ A♠ 2♠]`. `[J♠ Q♠ K♠ A♠ 2♠]` is a
length-5 pure run. Same wrap applies to rb runs.

Any stack on the board at turn-end that isn't one of the
three legal melds is "trouble" and must be cleared.

## A turn

A player's turn is a sequence of moves they make freely. Each
move is one of:

- Place a card from hand onto the board.
- Rearrange cards already on the board — split a stack, merge
  two stacks, pull a card across stacks, etc.

Mid-turn the board can be **dirty**: a partial pair waiting
for its third card, a singleton sitting alongside a target
stack the player intends to combine with. The player can
experiment, build partials, change their mind. **Undo is
available throughout the turn** to walk back any move.

The player keeps making moves until they end the turn —
typically once they've exhausted productive plays. At
turn-end, the board must be clean: every stack a length-3+
legal meld.

## Card draw between turns

The size of next turn's draw depends on what happened this
turn:

- **Zero cards played from hand** → draw 3.
- **Entire hand played** → draw 5.
- **Anywhere in between** → no draw.

So an unproductive turn refreshes the hand; a productive
one shrinks it; clearing the hand entirely earns the largest
refill.

## Winning

The first player to clear their hand is the **victor**.
Play continues after that — clearing your hand is the
victory event, not the end of the game.
