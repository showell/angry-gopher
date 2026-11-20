# Lyn Rummy solver: the resume kit

The solver is parked. These are its open threads, so un-parking starts from
evidence. [README.md](README.md) describes the solver itself.

**Queued:**

- **Certificates v2, the packing witness.** The counting certificate quotes
  capacities ("runs can hold only 2"); the lemma's window packing knows
  which cards are contended ("both black 8s need the 6♠"). Surfacing that
  witness sharpens the English. The same rails would give the puzzle hint's
  give-up an explanation, as the game hint has.
- **Deeper repair.** Human lines have set the repair budget each time it
  grew. Puzzle 80 is the first board past it: Steve's 12-verb line is plain
  repair vocabulary at about a dozen edits, beyond repair's depth, so the
  sweep answers with a 22-verb teardown. Read the game-19 comment in
  `repair.zig` before changing the node cap or the shortness prune.
- **The sets-three-away theorem.** Pulling rank r from the middle of a run
  leaves `[r−2 r−1]` and `[r+1 r+2]`, whose cheapest completions are ranks
  **r−3 and r+3**. So "the only red ten is buried mid-run" means "look at
  the 7s and the kings". It fits a lemma-as-kibitz surface, and perhaps
  repair's move order (try donors at ±3 first).

**Gathering evidence:**

- **Pure versus red-black runs.** Early in a hand pure runs look better, but
  red-black runs often leave easier placements for hard cards later in the
  turn. Steve decides the criterion once examples are in; raise it again
  with new ones.
- **Lemma-as-kibitz.** The per-rank lemma table (capacities, forced sets)
  is independent of the arrangement and meaningful to people: a kibitz
  surface that works from the multiset alone.
- **Player Two's feel.** It plays correctly and strongly. Its full-cover
  plays tidy the whole table, the human's half-built stacks included. It
  plays a satisfaction cascade with no hold-back layer: it never keeps the
  third 8 to starve you of the fourth. It is stronger than the beginner-first hints by
  design: one solver, two policies, tuned in one place. Agent turns run on
  the browser's main thread; a stutter would call for a worker thread for
  the wasm calls, keeping the budget.
- **Raising `GIVE_UP_STEPS`**, on evidence: `corpus_hard.txt` and puzzle
  78's multiset (unknown cold at the line, solved warm below it).

**Calibration.** Steve plays the mined boards against the solver: the loop
is `seed_sweep.zig`, `ops/mine_lynrummy_puzzle`, curation, the
`puzzle_gate` count bump, a human play, then `../ts/tools/replay_puzzle.ts`
and `calib.zig` to grade it. Boards in the band from about half the give-up
line to the line are challenging but solvable for him; mine upward from
there.
