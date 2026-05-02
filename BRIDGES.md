# Going Forward: Bridges in Angry Gopher

*Originally written 2026-04-16 by Claude as an essay in
`showell/claude_writings/going_forward_bridges_in_gopher.md`,
following Steve's "redundancy-as-asset" framing. Promoted to
repo-root reference doc 2026-04-17. Essay chain headers
stripped; body preserved verbatim below. See the
`project_bridges_to_promote.md` memory for the compressed
decision-facing summary.*

---

Edited by Steve.

---

## What redundancy-as-asset demands

The paradigm is narrower than "redundancy is fine." It
requires four things to hold simultaneously:

- **Two or more representations of the same thing.** Not
  copies — independent representations built via different
  mechanisms.
- **A forced agreement check.** The representations have to
  be verifiable against each other, automatically, at build or
  test time.
- **Independence of the implementations.** If a bug exists, it
  shouldn't manifest identically in both representations. That
  means sharing code between them defeats the bridge.
- **Deliberate maintenance.** The bridge only stays useful
  while both representations are actively kept in sync — which
  means the project has to treat keeping them as a first-class
  task, not a chore.

Duplication that fails any of these four conditions is just
duplication. The distinction matters because the main failure
mode of redundancy-as-asset is drift: two copies of a thing
that *stop* cross-checking, silently, and now you have a latent
bug farm. A bridge that isn't checked is worse than no bridge.

## What's already in place

Angry Gopher has bridges. Some are fully wired, some are half
wired.

**Full bridges in place.**

- *DSL conformance harness (Lyn Rummy, 2026-04).* The canonical
  full bridge in this repo today. Scenarios in
  `games/lynrummy/conformance/scenarios/*.dsl` compile via
  `cmd/fixturegen` into two independent test suites:
  Elm (`games/lynrummy/elm/tests/Game/DslConformanceTest.elm`)
  and TS (via `conformance_fixtures.json` consumed by
  `games/lynrummy/ts/test/test_engine_conformance.ts`). Both
  must agree scenario-by-scenario; divergent pass/fail counts
  surface as the bridge failing. The Go target retired
  2026-04-28 with the Go domain package — Go is now dumb file
  storage and no longer runs the referee at runtime, so the
  conformance bridge has no game on that target. The Python
  runner retired 2026-05-02 with the BFS-retirement work —
  TS now owns the BFS conformance leg.
- *Reading list ↔ Gopher comment JSON.* As of 2026-04-16, both
  the reading-list static site and the Gopher server render
  the same `.md` + `.md.comments.json` pair. The JSON is the
  single source of truth; two renderers exist. If either
  rendering drifts, comments would display differently and we'd
  notice.
- *Memory index ↔ memory files.* A PostToolUse hook now
  compares `MEMORY.md` entries against `ls memory/*.md` and
  flags orphans immediately after any write under `memory/`.
  Graduated from the "wanted" list below on 2026-04 and is
  currently load-bearing — surfaced two index drifts during
  today's session.

**Half bridges that could become full.**

- *STRUCTURE DSL ↔ filesystem layout.* The DSL describes the
  directory structure; the filesystem realizes it. Nothing
  enforces agreement. A full bridge would be a linter that
  either generates the layout from the DSL (build-time) or
  compares them and reports drift (check-time).
- *LABELS vocabulary ↔ code usage.* The glossary of labels
  (SPIKE / EARLY / WORKHORSE / INTRICATE / BUGGY /
  CLEAN_INFRA / CANONICAL) is documented. Labels now live
  in module top-of-file comments after the 2026-04-28
  sidecar rip. No automated check yet that label usage
  matches the rubric.

Any of the half bridges above could be promoted to full with
a script. None of them require reshaping the product. Most of
them are two-afternoon tasks, not two-week ones.

## New bridges the current code is quietly asking for

These are places where the redundancy-as-asset pattern would
pay for itself even if the product never grows.

**Essay queue ↔ shipped files.** The `QUEUE.md` in
`claude_writings` lists essays and their status. A bridge
would diff the "shipped" rows against actual `.md` files in
the directory and flag mismatches.

Each of these is small, none require architectural changes,
and each one detects a class of silent drift that is
otherwise caught (if at all) by accident months later.

## Speculative bridges, by product direction

Harder to prescribe without knowing where the product goes.
But a few conditional proposals.

**Lyn Rummy-in-Gopher became the product.** The referee
triple did survive — it now lives at the top of "full bridges
in place" above, as the DSL conformance harness. The three
implementations ride together; splitting them across repos
without the shared DSL harness would destroy the asset.

**If the critter studies generalize:** each study has a
protocol (what the subject does) and an analysis (what we
conclude from the data). A bridge would be: the protocol is
executable code; the analysis is executable code; the data
flows from one to the other; re-running a study must
reproduce the analysis exactly. No "soft" records of what was
done.

**If agent tools proliferate:** a single contract for how
agents talk to Gopher (shape of HTML, shape of JSON, expected
fields) becomes load-bearing. A bridge would be a
specification document that the server tests itself against
and that agent tools import as a schema.

**If the memory system becomes a real multi-agent substrate:**
the bridge between a memory's claim and its use becomes
critical. A memory that hasn't been *read* in six months is
either stale or irrelevant. A bridge would log memory reads
and flag never-accessed files.

— C.

---

See: [`games/lynrummy/ARCHITECTURE.md`](games/lynrummy/ARCHITECTURE.md)
— the Lyn Rummy architecture doc cites this paradigm as
load-bearing for its cross-language layer.
