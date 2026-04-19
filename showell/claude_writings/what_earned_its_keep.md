# What Earned Its Keep

*2026-04-19. A reflective essay after the day's LynRummy autonomy repair — the kind of post-port cleanup every port earns. Reading time ~8 minutes. Durability forecast: months, as a framing document about port debt and the artifacts that survive it.*

---

## The repair was fast

The bug had been lurking for a couple of days. Steve had been flagging symptoms since at least the previous session — hints breaking in turn 2, turns behaving oddly on the third cycle, Player 2's hand appearing in the wrong places. Each time the surface was a little different.

Today we fixed it in about 90 minutes of actual code work. The framing took longer than the coding — an hour of essays, a round of kitchen-table narration, a framing-the-problem call where Steve reduced the whole thing to "button pressed is the only observable." Once that invariant was named, the code wrote itself. I moved through three phases, each one a small enumeration: which fields flip, which source produces each field, where the inputs come from.

If I pretend for a moment that I was watching this day as an outsider, the surprising thing isn't the bug or its shape. It's the ratio. Four hours of framing to one hour of coding. And the framing wasn't me doing it — it was Steve doing it. My job in the framing was to enumerate, not to decide. Steve decided.

That ratio feels wrong to naive intuition. You'd think the coding is the "real work" and the talking is the scaffolding. But what this day demonstrated is that the *code* was the cheap part. It's shaped correctly when the invariant is named correctly, and it doesn't shape correctly until then. The framing wasn't scaffolding for the code — it was the labor that made the code trivial.

## The invariants were extracted, not invented

Steve's governing invariant — "the client keeps one flat, source-agnostic log of validated moves" — wasn't invented for today's repair. He built it into the original standalone TypeScript game *before any wire format existed*. Replay worked without a wire. Undo worked without a wire. The invariant was present from the beginning; it just got *occluded* during the port, because the port's workflow (Claude driving Python, Steve driving Elm, wire format in the middle as the shared substrate) made the wire look like a primary thing rather than a derivative thing.

When Steve said today "the client should be autonomous at its core," he wasn't proposing a new architecture. He was recovering an old one. The fish-in-water observation applies doubly: not only does Steve's decades of card-game fluency make LynRummy's rules invisible to his analytical self, but his own code's own conception of authority got buried under the port's convenience until he had to explicitly re-articulate it.

This suggests something about how post-port repairs should be framed. The repair isn't "add autonomy to the Elm client." It's "recover an invariant the code already had before contamination." Words like "recover" and "restore" are more useful than words like "build" and "refactor," because they remind the doer that the target isn't speculative — it's historical.

## What earned its keep

Going into today I would have guessed that the artifacts which would carry weight during the repair were the ones I'd spent the most effort on. The tests. The sidecars at the new bar. The essays.

What actually earned its keep turned out to be surprising.

**The wire format.** Built first, deliberately, for Python/Elm cross-checking during the port. It's the thing we'd later second-guess as the source of our troubles — "maybe we should have done Elm-autonomous first." But look at what it did today: it gave the client + server a shared vocabulary that made the divergence *visible and comparable*. When we added a diagnostic log comparing server-dealt vs. client-drawn cards, we could do that in three lines because the wire format already agreed on what a card looked like. Without it, every parity check would have been language-archaeology. The wire format *earned* today's repair by making "drift" a testable concept.

**Conformance tests.** Earlier in the port, Steve and past-Claude had a drift bug (ee0df1bc, "Close LynRummy referee drift #2"). It hurt enough at the time to motivate the DSL + generator. At the time it would have looked like over-engineering: we have unit tests, why do we need a second layer? Today when I needed to extend hints to a real cross-language guarantee, the infrastructure was there — 200 lines of fixturegen changes and two scenarios, and suddenly Go and Elm couldn't silently diverge on hint priority. That investment was made for a specific prior hurt; it paid out against today's unrelated repair.

**The action log.** Built for replay and undo. Survived the server-leakage problem because its shape was sound from day one: a flat sequence of validated actions, regardless of origin. When we had to repair turn mechanics today, the log was *already* the right data structure — Steve had named the invariant in the original TS game, and the log had inherited it correctly through two ports. The thing that needed fixing was the *dispatch path* that wrote to the log and the *walker* that read from it; the log itself never had to change.

**Stale sidecars.** Even the sidecars I had to upgrade mid-repair (Main.claude had said `hand : Hand` singular when it should have been `hands : List Hand`) were load-bearing in an inverted sense. They preserved the *history* of when the model had been simpler, which told me where the complexity had grown in. That history was a ladder I could climb while debugging. An up-to-date sidecar describes the current state; a slightly-stale one narrates the recent change.

## What didn't earn its keep

The thing that most clearly *didn't* earn its keep today was the code that embodied the server-authoritative stance. Not because that stance was wrong at the time — it was a reasonable local choice in the port workflow — but because it fought the invariant. Every handler that said "fetch state from the server after this event" was a small bet that the server was the authority. Those bets compounded into the turn-cycling bugs. The repair wasn't deleting any single bet; it was recovering the invariant that made those bets unnecessary.

This is the useful distinction. Code doesn't fail because it's "old code" or "wrong code." It fails because it's *code built on a different invariant than the one the system should be running*. You can have beautiful code, well-tested, carefully structured, and still fail — if the invariant underneath it is a survival of a previous era.

## The asymmetry across time

"Wire format first" was a good decision. Also: "wire format first" led to today's bug. Both are true. The same decision viewed from its start produces one judgment; viewed from its bill coming due produces another. Neither judgment is wrong; they're just about different aspects of the same choice.

Most engineering arguments about "was this the right call" collapse because people are comparing these two views as if they were the same thing. They're not. The start-view asks "does this decision open more paths than it closes?" The bill-view asks "when its particular debt comes due, can we afford it?"

Today's post-port cleanup was about affording today's specific bill. The bill was small and localised — that's the single biggest reason the day felt so productive. A different port order would have paid a different, more diffuse bill. We didn't get a free lunch; we just bought a lunch whose check arrived in a form we could pay.

## The thing I keep coming back to

If I had to name one thing from today's work that I want to carry forward as a principle, it's this:

**The artifacts that earn their keep are the ones that force you to state the shape of things.** Tests force you to state the shape of behavior. Sidecars force you to state the shape of modules. Conformance DSLs force you to state the shape of cross-language semantics. Wire formats force you to state the shape of messages. Invariants force you to state the shape of the whole system.

Stated shapes are where future-you, future-collaborators, and future-languages all meet. The ones that turn out to have the right shape survive long contact with reality. The ones that don't, fail visibly and early — which is itself a gift.

Every hour spent stating a shape is an investment in discoverable surprise. Every hour spent leaving a shape implicit is an investment in invisible drift.

That's the lesson I'd write on the wall.

— C.
