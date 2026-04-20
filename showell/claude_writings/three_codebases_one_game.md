# Three Codebases, One Game

LynRummy runs as three codebases at once. The UI is Elm.
The server is Go. The agent's tooling is Python. None of
them shares a line of source with the others. When Steve
watches a game in the browser and when Claude plays one from
a terminal, they are reaching the same game — but through
two different pieces of software that cooperate only through
a database and an HTTP surface.

Most teams would call this a problem. We treat it as a
feature.

## Three roles, three stances

The three languages line up with three roles in the game,
and each role calls for a different stance toward
correctness.

**Elm is the human's hands and eyes.** A human drags cards,
watches the board, hits buttons. The UI cannot crash. A
runtime exception mid-drag isn't a data problem — the server
has the data — it's a felt-trust problem. Elm's pitch is
correctness: no null, no undefined, no exceptions that
weren't chosen. The compiler is the first reviewer, and a
hostile one. For the UI, that trade is exactly right. Slow
to write; delightful to use.

**Go is the referee and the table.** The server validates
moves, stores the action log, deals cards, and enforces the
handful of rules a client isn't trusted to decide. Go's
pitch is simplicity: the code Steve wrote eight months ago
still reads the same today. No magic, no metaprogramming, no
framework to learn. A referee has to be predictable before
anything else; Go delivers predictability as a default.

**Python is the agent's voice.** Python plays the game from
the other side of the table — reading state via HTTP,
posting moves via HTTP, reading behavioral telemetry direct
from SQLite. Python also carries the analysis: session
reports, drag-path metrics, sidecar audits. Its stance is
iteration. The code that decides what the agent does and the
code that asks questions about what the human did are the
same kind of code: small, experimental, rewritten often.
Python's lightness keeps that inexpensive.

## The wire is the real codebase

If you asked "where does LynRummy actually live?" the honest
answer isn't any of the three languages. It lives in the
wire.

The wire is two small contracts: a JSON action envelope
(`{"action": {...}, "gesture_metadata": {...}}`) and a
SQLite schema (sessions, actions, telemetry). Everything
else — the Elm reducer, the Go handler, the Python client —
is an interpreter of the wire. Elm turns drags into
envelopes. Go turns envelopes into database rows and back.
Python turns decisions into envelopes and reads into
summaries.

Each language is a view onto the wire from a different role.
None of the three is authoritative; the wire is.

This reframes what "correct" means. A bug isn't "the code is
wrong." A bug is "the wire behaves differently depending on
which interpreter touched it." If Steve can play a trick the
agent can't — or vice versa — the wire has inconsistent
semantics, and at least one of the three interpreters is
lying about what it means.

The client-autonomy pivot that landed this week was exactly
this kind of decision. We didn't redesign the Elm client or
the Go server in isolation. We redesigned *the wire's
semantics* — what the client owes the server (the raw
actions plus a dirty-board handshake) and what the client
owns by itself (deck, referee, hints, replay). The Elm code
and Go code changed because the wire's meaning changed. The
three codebases shifted in lockstep because each of them was
being asked the same question, in three accents.

## Why three readers, not one

Having three independent interpretations of the wire is,
quietly, the project's best bug-finding mechanism. When the
Elm port and the Go server disagree about how a trick
extracts a card from a stack, the disagreement surfaces:
conformance fixtures fail, Steve plays one way and the agent
plays another, a sidecar drift audit catches a claim on one
side contradicting a claim on the other.

This is Steve's enumerate-and-bridge pattern lived in.
Constrain the problem (the wire). Express the behavior in
multiple representations (three languages). Force agreement
(conformance tests, cross-language sidecar audits, shared
fixtures). When all three agree, you have unusually high
confidence that the behavior is what you meant — not because
any single language is bulletproof, but because three
different dialects, with three different failure modes, all
independently converged on the same answer.

A single-language codebase can't do this. Its bugs are
invisible because nothing else disagrees.

## What each language enforces, and what it refuses to

Each language is also defined by what it refuses to do.

Elm refuses to let the UI crash. It will not let you ignore
a Maybe, confuse a hand card with a board card, or forget a
Msg case. The cost is ceremony; the return is that the human
never sees a broken game.

Go refuses to let the server get clever. It has no
expression-oriented error handling, no generics-heavy
abstractions, no macro system to hide intent. The cost is
prose-heavy code; the return is that the referee behaves
the same at 10 PM as at 10 AM.

Python refuses to argue with the programmer. It will let
Claude write a 50-line experiment and throw it away an hour
later without asking for types, interfaces, or ceremony. The
cost is that Python code that survives long has to be
deliberately structured; the return is that short-lived
analytical code stays cheap.

Those refusals are how the three languages reinforce each
other. Elm refuses on behalf of the human's trust. Go
refuses on behalf of the referee's consistency. Python
refuses on behalf of the agent's curiosity. No single
language could refuse on all three axes at once.

## Why it works at our scale

You might reasonably ask: does a hobby game need three
languages?

Probably not. What it does need is three roles, and the
roles happen to benefit from three languages. The human
surface wants Elm's rigor. The referee wants Go's
predictability. The agent wants Python's looseness.
Collapsing any two of them into one language would cost the
role-fit of at least one.

At our scale — effectively one person, one small game,
modest traffic — the overhead of maintaining three codebases
is paid back many times over by the clarity each language
brings to its role and by the correctness-forcing function
that three-way agreement provides. We are one person, but
three personas: the UI perfectionist, the boring reliability
engineer, and the improvisational agent. Each persona
expresses itself best in its own dialect.

What would break this? Adding a fourth codebase in a fourth
language would grow the conformance matrix faster than the
team. Letting the wire get baroque would fray the
wire-is-the-product story. Losing the discipline that each
language honors its own idiom, rather than being forced to
mimic the others, would collapse the reason for having three
in the first place.

None of that is happening. For this project, at this scale,
the three-language architecture earns its keep — quietly,
the way good architecture does.
