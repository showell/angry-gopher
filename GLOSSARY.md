# Glossary

**As-of:** 2026-04-17 (late pm)
**Confidence:** Firm where terms are already in code; Working where they live only in chat/memory so far.
**Durability:** Stable vocabulary layer — entries are added when a word earns its place, not to document every passing phrase. Prune aggressively.

Words Steve coined or borrowed that now carry real weight — in code identifiers, commit messages, memory entries, or conversation. If you find yourself reaching for a generic CS term when one of these already fits, use the word here instead. New entries welcome when they survive a few uses.

## Dev harness — labels & maturity

Labels that appear in `.claude` sidecars to signal the state and role of a file or module. Used by agents at tool-use time to pick the right mindset.

| Term | Meaning |
|---|---|
| **SPIKE** | New exploratory work. Expect churn; don't build on top of it yet. |
| **EARLY** | Kept but not yet stable — survived past SPIKE, still learning its shape. |
| **WORKHORSE** | Stable, load-bearing code. Default for mature modules. |
| **INTRICATE** | What distinguishes the app from CRUD — needs a different mindset; don't simplify mechanically. |
| **BUGGY** | Visibly broken feature we're keeping around; advertise the status, don't hide it. |
| **CLEAN_INFRA** | Tool promoted from ad-hoc script to load-bearing infrastructure. |
| **CANONICAL** | The single source of truth for a concept; other copies follow. |

## Collaboration & working style

Terms for how Steve and Claude work together. These shape process, not product.

| Term | Meaning |
|---|---|
| **Kitchen-table test** | Asking "would this feel right at an actual card table?" — Lyn Rummy's UX tie-breaker. |
| **Rip** | Delete code fearlessly — removing an un-earning feature is a first-class skill, not a regret. |
| **Consolidate knowledge** | The post-iteration exercise of promoting durable artifacts (sidecars, memories, essays, glossary entries, git tags) from a completed push of work. Done *in the flow*, not later — it both compresses what we just learned and pre-loads future-us. Named 2026-04-17 by Steve on the Writing the Sidecars essay. Canonical label for these exercises in commit messages and in-session framing. |
| **Ebb and flow** | The oscillating rhythm of our iteration: add complexity for realism and framing; scale back to study a single interaction; re-introduce the complexity. Neither pole alone is the answer — the study needs realistic conditions to matter, the tuning needs stripped-down conditions to move fast. Named 2026-04-17 on *Two Directions* (chosen from ~12 candidates including *breathing*, *pole-flipping*, *lab and field*). Canonical term in commit messages and in-session framing for iteration-phase work. |
| **Zoom in / zoom out** | General-vocabulary verb pair for a *specific move* within ebb and flow. *Zoom in:* narrow focus, isolate a variable, drop context, tight feedback. *Zoom out:* widen focus, see the whole, re-engage complexity, sanity-check. **Caveat:** prone to false cognates — "zoom in" can mean literal camera-zoom, UI-zoom, mental-focus-on-detail, etc. Use when the *direction* (narrower vs wider) is the load-bearing meaning; reach for a more specific term if the semantics could conflate. |

## Cognition & collaboration (added 2026-04-16)

Terms from the Field Notes study. Each earned its place by clarifying
a pattern we'd been using without a handle.

| Term | Meaning |
|---|---|
| **Enumerate-and-bridge** | Steve's core design instinct: constrain the domain small enough to cover exhaustively, express the behavior in ≥2 independent representations, force them to agree. Disagreement is the signal. The LynRummy referee triple, `fixturegen`, and the Wacky VM's polynomial-vs-simulator cross-check are canonical examples. |
| **Grind / incubate / re-encounter** | The three-stage pipeline through which recognition lands: *type* (produce a persistent artifact) → *incubate* (sleep, walk, distance) → *re-encounter* (re-read, return with fresh eyes). You cannot skip the grind and go straight to the walk around the lake. Steve's re-derivation of Wallas (1926) with better verb-tempo. |
| **Persistence of externalization** | Why typing works as a thinking medium where silent thought does not: typed text is stable and re-scannable. The fingers produce an artifact the future-self can inspect. Speech lacks this; silent thought lacks this. |
| **Pragmatic awareness** | Active recognition of trade-offs, distinct from *pragmatic acceptance*. Steve's term for consciously allowing his math brain to atrophy because economic incentives didn't pay for it, without pretending the atrophy isn't real or that the choice wasn't his. |
| **Structural math taste** | The compiled-into-instincts residue of mathematical thinking — preference for small surface area, algorithmic recognition, invariant-first design — that remains even when explicit math (*active math*) is not being performed. The thing inferior programmers miss when they claim "you don't need math." |
| **Double-voicing** | Holding two seemingly-contradictory positions deliberately and simultaneously, aware of both. Steve's habit of *generous attribution* (others do this too) paired with *candid ranking* (I'm a particularly sharp instance of it). Not contradiction; deliberate dual register. |

## UI design (added 2026-04-17)

Terms from the Cook-Levin VM simulator UI iteration. Each earned its place by naming a pattern that was doing load-bearing work in design voting.

| Term | Meaning |
|---|---|
| **Protagonist** | The main-character element in a mutable-state visualization — the thing whose trajectory IS the point. Must be visually dominant, clearly reactive, always present. Register in a VM UI; player-marker in a game UI; currently-editing cell in a spreadsheet. Simplification that removes the protagonist regresses the UI regardless of its local-redundancy rationale. Test: after your simplification, is the protagonist still on screen? |
| **Dock-beside** | Animation pattern where an action label travels from its source (e.g., a clicked button) to *adjacent* to its target (e.g., the register), pauses briefly visible, then fades as the target reacts. Preserves the "instruction moves toward register" gesture without letting them occupy the same physical space. |
| **Tape-consumed** | Turing-tape motion: instructions sit on a tape that slides past a fixed head position; finished instructions clip out of a viewport; the next instruction always arrives at the head so the user's click target stays stable. Auto-scroll-into-focus is the ergonomic payoff. |
| **Time's arrow** | Property of a UI axis (usually vertical top-to-bottom) that reads as temporal ordering rather than arbitrary spatial distance. When the axis reads as past → present → future, "action at a distance" along it resolves into causality. The axis itself is the bridge. |
| **Phase, not motion** | Observation that in a well-designed sequence UI, commands don't physically move between regions — their *status* changes (pending → at-head → spent) while they stay in place. Motion isn't required to communicate execution; phase change with preserved identity is. |
| **Proxy constraint** | A stated design constraint that's actually a shorthand for a softer underlying rule. "Reduce click-to-effect distance" was a proxy for "effect must read as phase-change, not teleport." Relaxing the proxy by satisfying the softer rule through a different route unlocks designs the literal proxy forbade. Worth asking *once per design problem*: what is this constraint really protecting? |

## How to add an entry

1. The term has to already be doing work — used in code, commits, or a memory entry — not just a candidate phrase.
2. One-line definition, concrete, no hedging.
3. If it's project-specific, put it in the right section; if it earns cross-project life, promote it up.
4. Remove stale entries during the weekly docs audit. A glossary that grows without pruning stops being load-bearing.
