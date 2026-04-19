# The Wire Is Not Our Friend

*2026-04-19. Forward plan — animation as a mostly isolated problem, with the Elm client's simplicity as the governing constraint. Durability forecast: ~1 week (until the replay scaffold lands) or indefinite as a framing document. Supersedes the earlier `instant_replay_scaffold.md` draft, which got the two-player shape backwards.*

---

## The invariant

The Elm client has one job for as long as we can keep it there: **record validated moves into one flat log and render the resulting state**. Source doesn't matter. Local drag, wire event, replay tick — once a move has passed validation, it's just a move. Goes in the log, same slot as every other move. That's it.

Steve built this invariant into the original standalone TS game before any wire format existed. Replay worked before the wire existed. The wire was layered in later, and it added real complexity, but the invariant survived: after validation, the client didn't care where the move came from. It had one log.

We have drifted from that invariant during the Elm port because the port itself was a two-player workflow (Claude on Python, Steve on Elm, wire carrying both). Two-player-ness was the workflow, not the game. Everything downstream that assumed two-player-ness as foundational — including my own earlier essay — was mis-framed.

## The wire is not our friend

The wire format exists for good reasons. Claude ↔ Steve coordination during porting. Cross-device sync. Multi-player, eventually. We can't throw it away. But we also can't let it dictate the Elm client's complexity budget.

Every time the wire tries to leak into the core — "how do we know a move came from the other player?", "what if seq 42 arrives before seq 41?", "do we need an authoritative source-of-truth HTTP fetch?" — the answer should flow from the invariant, not the other way around. Validated move → log → render. The wire is one input at the validation boundary; nothing past that boundary knows it exists.

This is a discipline, not a feature. It looks like restraint at every design decision: keep the wire in its lane, keep the client's core loop small.

## Animation, cleanly stated

The animation problem is: **a card must be continuously visible as it travels from source to destination over roughly 300ms.** Teleport breaks the illusion; smooth motion at physical-world speed preserves it.

That problem is fully defined without any wire at all. Given a log of moves and a way to render state, animation is a question of "how do I interpolate rendering between two consecutive log entries." Single client, single log, single walker.

Replay is the harness. The client already intends to keep a log (invariant). Walking the log with a visible delay — even initially with teleport — gives us a single-player sandbox in which to solve the animation problem exactly once. Everything else (live play, remote moves, turn ceremony) rides on the same walker later. Nothing new to invent.

## The client shape we want

```
Model = { ...current snapshot fields...
        , actionLog : List WireAction
        , replay   : Maybe ReplayProgress
        }
```

Two additions. That's all the structural change this buys us.

- `actionLog` appended at the validation boundary (wherever a move is about to be dispatched). *Working confidence* — I need to locate every such site; likely ~5 in `Main.elm`.
- `replay` is `Nothing` during live play and `Just { step : Int }` during replay. The walker reads from `actionLog`, applies via `LynRummy.Replay.applyAction`, ticks `step`.

`Replay.applyAction` exists and is single-hand. Single-hand is exactly the shape we want — the log is flat, the two-player seat-flip (CompleteTurn) is just another log entry that the walker applies pass-through.

## Concrete first milestone

1. Add `actionLog` to `Model`. Append at every action-dispatch site.
2. Add a top-bar "Instant Replay" button. Sets `replay = Just {step=0}`, resets snapshot fields to initial.
3. `Time.every 500 ReplayTick` while `replay` is non-Nothing. Applies `log[step]`, increments step, stops at end.
4. Teleport only. No animation yet. Prove the walk.

Once that walks, the animation layer goes on top of the walker — one place to interpolate, one place to time, one place to stare at while we tune the 300ms feel.

## Deferrals (and why)

- **Wire refinements** — polling, SSE, remote seq handling. Downstream of a working replay walker; different problem.
- **Offline authority robustness** — server-down play, seeded init state, conflict handling. Directionally aligned with the invariant but not required for the animation milestone.
- **Two-player coordination** — irrelevant until animation reads as smooth on the single-client harness.
- **Animation polish** — teleport is enough for the first walker. Motion design comes after.

## What I'll watch for

*Tentative, the places where I'd expect the invariant to push back.*

- **Undo.** The simplest framing says undo is just a log entry that replay replays. Needs confirmation against the current Undo implementation — it currently resyncs via `/state`, which may or may not have already added an Undo entry to the log. If it hasn't, we have a small leak in the invariant to repair.
- **Turn-ceremony popups during replay.** Popups are rendering, so suppression during replay is just a `replay == Nothing` check at the popup site. Easy, but needs an actual decision (suppress, or play them with reduced timing).
- **TrickResult actions** from `/hint`. Their diff (`stacksToAdd / stacksToRemove / handCardsReleased`) is already in the action JSON, so `Replay.applyAction` walks them straight. No special case expected.

— C.
