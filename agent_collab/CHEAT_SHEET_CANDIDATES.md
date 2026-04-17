# Porting cheat sheet — candidate edits

**As-of:** 2026-04-17
**Confidence:** Working — running list, not yet promoted.
**Durability:** Drain into `PORTING_CHEAT_SHEET.md` in batched edits after each port reaches a natural break. Entries deleted once promoted (git log carries the history).

A running list of observations during live porting work that
might deserve a spot in `PORTING_CHEAT_SHEET.md`. Per the
ruling on `inventory_of_a_partial_port.md` para 20: capture
now, defer the actual cheat-sheet edits until a batch is
ready.

Each entry: one-line claim, context, status. Promote when
confident the claim generalizes (a second data point is the
usual threshold). Delete when promoted.

---

## 1. Partial ports start with inventory (Step 0)

- **Claim:** Before the usual "Before you touch the code" +
  "Survey phase" steps, a partial port needs an inventory
  step that enumerates what's already ported and subtracts
  it from the source. Output: a TS→Elm (or equivalent) pairing
  table with per-module confidence notes. Only then do the
  rest of the cheat-sheet steps apply, on the unported
  remainder.
- **Why it matters:** Without this, a partial port risks
  redundant work on already-ported modules, gaps in
  understanding what the durable layer covers, or
  (catastrophic) mistakenly ripping durable code. The
  study-rip earlier today nearly did the last one; the
  Layer-1/Layer-2 clarifying question was a one-off version
  of this step.
- **Source:** `inventory_of_a_partial_port.md` (2026-04-17
  LynRummy UI port kickoff).
- **Generalization test pending:** Need a second partial-port
  data point before promoting. Likely candidates: a future
  Elm→Go parity refactor, an Angry Dog Roc/Odin/Zig port.
- **Status:** Seeded as cheat-sheet candidate. Do not edit the
  cheat sheet yet.

---

## How to add an entry

Write below the previous entry. One-line claim. Context.
Generalization test if not obvious. Status. Keep each entry
short — the essay that surfaced the insight is the long form;
this file is index.
