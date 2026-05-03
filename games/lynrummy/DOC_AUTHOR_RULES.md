# DOC_AUTHOR_RULES — how Lyn Rummy docs stay trustworthy

**Status:** Standards, 2026-05-03. Synthesized from
`claude-steve/random239.md` (the trust-calibration framing) plus the
two audits at `random240.md` (corpus classification) and
`random241.md` (concrete drift hits).

The whole reason these rules exist: a wrong doc the reader
*trusts* is worse than no doc at all — it builds a false mental
model that costs hours to unlearn. Steve's grounding axiom: **Steve
is the authority on rules and design; the code is the authority on
what actually happens at runtime.** Docs serve those two authorities;
they don't substitute for them.

---

## Pick the right archetype before writing

Every doc is one of:

- **DECISION** — records a choice at a moment, often dated.
  Stays *accurate* even if overturned. Example: `ARCHITECTURE.md`
  sections.
- **INVARIANT** — describes data shapes, contracts, validation
  gates. Changes rarely, only via deliberate breaking changes
  shipped in the same PR. Example: `python/SOLVER.md` § "Data
  shape."
- **REFERENCE** — describes how a current subsystem works. Drift-
  prone unless tightly scoped + dated. Example: `ts/ENGINE_V2.md`.
- **OVERVIEW** — short orientation + outbound links. Example:
  `README.md`, `ENTRY_POINTS.md`.
- **FROZEN ESSAY** — explicitly time-stamped reasoning, never
  updated. Example: `claude-steve/random*.md`.

If your draft is a **STATUS** doc ("we're using X right now",
"Round 4 retired Z", "what's ported and what's deferred"), stop.
Status prose decays automatically. Either:
1. Reframe as a dated DECISION ("On 2026-05-02 we made TS the
   canonical engine — here's what carried, here's what didn't"), or
2. Delete and let the code answer "what is true now."

---

## Calibration block at the top

Every REFERENCE, INVARIANT, and DECISION doc opens with two lines
the reader uses to scale trust:

```
**Status:** <one-line current state>
**As of:** YYYY-MM-DD
```

If the doc has an end-of-life condition, add:

```
**Expires:** when <grep-able condition>
```

`ts/ENGINE_V2.md` and `python/SOLVER.md` are the templates. The
grep-able expiry matters: `ELM_HINTS.md` self-declared expiry in
prose; nobody swept for it; the doc rotted in place for weeks.

---

## Cite or qualify

A claim about the code is one of:
1. **General principle** — "BFS retires at most 2 cards per move."
   No citation needed.
2. **Citation** — "`src/engine_v2.ts` ranks states by `f =
   plan_length + heuristic`." Path/line is checkable.
3. **Dated** — "As of 2026-05-02, the production path is `bfs.ts`."

Plain unqualified prose ("the engine uses A* with state-sig dedup")
is the failure mode. A reader can't tell whether the claim is still
true; six months from now nobody can either.

For symbol or path mentions, prefer backticks
(`` `src/engine_v2.ts` ``) — `tools/doc_xref.py` then verifies them
automatically.

---

## Aspirational vs descriptive — segregate

Reference prose is **descriptive**: it describes what is. Words like
"will", "planned", "next", "TODO" never appear in reference body
prose; they live either in:
- A clearly-marked `## TODO` section (don't invest if it's been
  there >2 weeks — file an issue or delete), or
- `claude-steve/MINI_PROJECTS.md` (the queued-work index).

A doc that says "X is on life-support; we will retire it next
quarter" is two distinct claims: status (X is on life-support) and
intent (we will retire it). Status belongs in the body; intent
belongs in MINI_PROJECTS or it rots.

---

## No hand-written counts

Numbers like "214/214 leaf scenarios" or "189 scenarios, 770 tests"
are correct at write-time and wrong by next week. If a number is a
property of generated artifacts, do one of:
- **Link to the artifact.** "See `npm test` output."
- **Link to the script that prints the number.** "Run
  `ops/check-conformance` and read the summary."
- **Date it.** "(214 as of 2026-05-02.)"

Never bare numbers in reference prose.

---

## Single source of truth for enumerations

When a doc enumerates anything that lives in code (op names, module
list, fixture types), the doc must either:
1. Say "see `<canonical_path>` for the live list" and stop, or
2. Be regenerated mechanically from the canonical source.

Hand-copied enumerations always drift. The canonical example of the
failure: `ENTRY_POINTS.md` once listed 9 fixturegen ops by hand;
two were fictional and the real registry had 23. Now it points at
`opRegistry` in `cmd/fixturegen/main.go` and is unfalsifiable.

---

## Doc location conveys archetype

- `*_SPEC.md` lives near what it specifies (not under `tests/`).
- `*_STATUS.md` is a smell — read the archetype rule above.
- `BACKLOG.md` files rot because nobody sweeps them. If you want an
  issue tracker, use one.
- Project-artifact docs (`PORTING_NOTES`, `*_ROADMAP`) belong with
  the project; when the project ends, fold the durable bits up
  one level (memory, cross-cutting handbook) and delete the wrapper.

---

## When you touch a doc, run doc_xref

```
tools/doc_xref.py path/to/your_doc.md
```

Catches broken markdown links and missing backtick paths in a few
seconds. Add `--strict` if you want backtick identifiers verified
too. Run `tools/doc_xref.py --all` before committing a sweep.

---

## Pointers

- `claude-steve/random239.md` — the trust-calibration framing essay.
- `claude-steve/random240.md` — corpus classification audit
  (which docs to keep, rewrite, delete).
- `claude-steve/random241.md` — concrete drift hits across 6 docs.
- `tools/doc_xref.py` — the heuristic verifier these rules pair with.
- `ts/ENGINE_V2.md`, `python/SOLVER.md` — templates worth imitating.
