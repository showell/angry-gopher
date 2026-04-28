# Agent orientation quiz

This is a battle-test for the orientation section in
`games/lynrummy/python/README.md`. A fresh agent who has only the
README + repo on disk should be able to complete this without
escalating.

## Task

Produce a JSON file at `/tmp/quiz_lynrummy_game.json` containing a
fresh, randomly shuffled Lyn Rummy game state — exactly the shape
the server accepts as `initial_state` on `/new-session`.

Constraints:

- **Use the existing public API.** Do not reimplement shuffling,
  card construction, or board assembly. The orientation section
  tells you where the public surface lives — go find it.
- The output must be a single JSON object containing the full
  game state (board + hands + deck + discard + active player).
- Use 2 players, 15-card hands. (Defaults are fine.)
- No DB calls, no HTTP. Pure Python.

## Verifying

Run:

    python3 games/lynrummy/python/quiz_verify.py /tmp/quiz_lynrummy_game.json

Exits 0 on pass, 1 on failure with diagnostics. The verifier checks
structural invariants (104 distinct cards, hand sizes, opening
board shape) — it does NOT compare to a fixed seed, so any valid
shuffle passes.

## What this quiz is testing

Whether the orientation section in the README leads you to the
right entry point quickly. If you find yourself rebuilding a deck
or computing card values from scratch, you missed the orientation —
back up and re-read it.

When done, briefly tell the orchestrator:
1. Which file/function you used.
2. How you found it (which README section pointed you there).
3. Any orientation-step that was unclear or led you astray.
