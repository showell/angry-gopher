# Glossary

**As-of:** 2026-04-15
**Confidence:** Firm where terms are already in code; Working where they live only in chat/memory so far.
**Durability:** Stable vocabulary layer — entries are added when a word earns its place, not to document every passing phrase. Prune aggressively.

Words Steve coined or borrowed that now carry real weight — in code identifiers, commit messages, memory entries, or conversation. If you find yourself reaching for a generic CS term when one of these already fits, use the word here instead. New entries welcome when they survive a few uses.

## LynRummy — gameplay & physics

Terms specific to how LynRummy works as a card-table simulation. Most of these shape both the Elm/TS code and how Steve talks about play.

| Term | Meaning |
|---|---|
| **Kitchen table** | The physical-play reference. Every UI choice is measured against "what would happen at the kitchen table" — humans own the board, cards drag as physical objects, chaos is fine. |
| **Miracle** | Layer-2 interpretation that turns a dropped card into a meld when physics alone would leave it loose. Baseline is physics; miracles are layered on top at drop time. |
| **Tidy** | Moving cards around on the board *without* landing on a meld target. Not a separate gesture — just "a move that didn't trigger a miracle." |
| **Lift** | Long-press extract — the chosen override for pulling a single card out of a stack. Stacks stick together by default; lift is the explicit exception. |
| **Ghost** | The landing-slot preview shown under a held card (where it will snap if released). |
| **Grip illusion** | The feel of holding a card while dragging — the property the held-card feedback has to preserve. Held card stays inviolate; feedback lives around it. |
| **Love at first sight** | Auto-meld trigger — the moment a dropped card recognizes it belongs with a group. |
| **Cheese** | Trial reward in critter studies — what the rat gets for a correct choice. |

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
| **Librarian** | The agent's role of tracking IDs, handles, "which game was that?" — Steve thinks in labels and recency; agent owns the lookup. |
| **Knobs** | Up to 3 named per-project knobs rated 1–10; 10 means excellence is demanded on that axis. |
| **Frozen doc** | A doc explicitly set up as pre-fix truth for a walkthrough; read-only for the duration even as code changes around it. |
| **Kitchen-table test** | Asking "would this feel right at an actual card table?" — LynRummy's UX tie-breaker. |
| **Rip** | Delete code fearlessly — removing an un-earning feature is a first-class skill, not a regret. |
| **Genius vs. folly** | Steve's aphorism: "humans are good at turning problem A into problem B. Usually that's our folly, but sometimes that is our genius." A reframe is *genius* when problem B has a terminating check (finite search, verifiable absence); *folly* when B is just another open-ended rearrangement. |
| **Robbing Peter to pay Paul** | The kitchen-table name for the folly side of a reframe — a "solution" that relocates the difficulty or undoes earlier progress. Canonical label when naming the anti-pattern. |

## How to add an entry

1. The term has to already be doing work — used in code, commits, or a memory entry — not just a candidate phrase.
2. One-line definition, concrete, no hedging.
3. If it's project-specific, put it in the right section; if it earns cross-project life, promote it up.
4. Remove stale entries during the weekly docs audit. A glossary that grows without pruning stops being load-bearing.
