# /tutorial — the beginner tutorial

A public, ungated page teaching the game: rules-complete quick start,
meld figures, two live widgets (drag-the-loose-cards, find-the-chain),
and a narrated mid-game board. Served by `zig-server/src/tutorial.zig`
(@embedFile); gated by `ops/test_tutorial` (inside `check_lynrummy`).

Soft-parked since 2026-07-11, content-complete. **Steve owns the
remaining-gaps list** — don't re-derive it; the one he has named: the
page doesn't demonstrate playing a card from your hand well, and his
plan is a real photo (on him).

Standing decisions:

- **Pure HTML + plain JS. No Elm, no TypeScript, no solver.**
  `tutorial.js` re-ports the rules and board gestures from the Elm
  `Lib/` code, which is the SPEC to port from.
- Tone (landed after four canary rounds): warm artifact, analytical
  game — the page claims the analytical register in sentence one and
  demonstrates it with content, not adjectives.
- Prose card tokens wear truthful `lr-red`/`lr-black` spans; widget
  prompts are required `data-prompt` attributes — both gate-enforced
  (`check_tutorial.js`).
- Voice experiments (a drier rulebook register in places; a better
  analogy for scoreless competitiveness) are explicitly Steve's to
  green-light. Competitiveness stays understated on the page.

If work resumes, the natural growth path is porting the PUZZLES (not
the game) to plain JS — `tutorial.js` already has boards, gestures,
and the clean-board check, and newcomers gravitate to puzzles.
