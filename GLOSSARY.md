# Glossary

Words Steve coined or borrowed that now carry real weight in
this project — used in code identifiers, commit messages,
memory entries, and conversation. If a generic CS term and
one of these terms both fit, use the one here.

Keep this list short. Entries earn their place by surviving a
few uses; remove entries that stop earning their keep.

## Module maturity labels

Used in module top-of-file comments to signal a file's role
and state. Agents pick the right mindset based on the label.

| Term | Meaning |
|---|---|
| **SPIKE** | New exploratory work. Expect churn; don't build on top of it yet. |
| **EARLY** | Kept but not yet stable — survived past SPIKE, still learning its shape. |
| **WORKHORSE** | Stable, load-bearing code. Default for mature modules. |
| **INTRICATE** | What distinguishes the app from CRUD — needs a different mindset; don't simplify mechanically. |
| **BUGGY** | Visibly broken feature we're keeping around; advertise the status, don't hide it. |
| **CLEAN_INFRA** | Tool promoted from ad-hoc script to load-bearing infrastructure. |
| **CANONICAL** | Single source of truth for a concept; other copies follow. |

## Working-style vocabulary

How Steve and Claude work together. These shape process, not
product.

| Term | Meaning |
|---|---|
| **Kitchen-table test** | "Would this feel right at an actual card table?" — LynRummy's UX tie-breaker. |
| **Rip** | Delete code fearlessly — removing an un-earning feature is a first-class skill, not a regret. |
| **Consolidate knowledge** | The post-iteration exercise of promoting durable artifacts (memories, essays, glossary entries, module docstrings, git tags) from a completed push of work. Done in the flow, not later — both compresses what was just learned and pre-loads future-us. |
| **Ebb and flow** | The oscillating rhythm of iteration: add complexity for realism and framing; scale back to study a single interaction; re-introduce the complexity. The study needs realistic conditions to matter; the tuning needs stripped-down conditions to move fast. |
| **Zoom in / zoom out** | Verb pair for a specific move within ebb and flow. *Zoom in:* narrow focus, isolate a variable, drop context. *Zoom out:* widen focus, see the whole, re-engage complexity. Use when the *direction* (narrower vs wider) is the load-bearing meaning; reach for a more specific term when the semantics could conflate. |
| **Enumerate-and-bridge** | Steve's core design instinct: constrain the domain small enough to cover exhaustively, express the behavior in ≥2 independent representations, force them to agree. Disagreement is the signal. The LynRummy conformance bridge (`BRIDGES.md`) is the canonical instance. |

## Adding entries

1. The term has to already be doing work — used in code,
   commits, or a memory entry — not just a candidate phrase.
2. One-line definition, concrete, no hedging.
3. Prune entries that stop earning their keep. A glossary
   that grows without pruning stops being load-bearing.
