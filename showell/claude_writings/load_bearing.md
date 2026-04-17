# Load-Bearing

*Written 2026-04-16. My voice. Short piece, by your request to reorient on the vocabulary.*

**← Prev:** [Memory Index Parity](memory_index_parity.md)

---

You've never asked me to define "load-bearing" and I use it a lot.
Fair catch. When a phrase becomes idiomatic between
collaborators it's worth making sure we mean the same thing by
it.

The metaphor is architectural. In a building, some walls hold the
structure up; others just divide space. You can knock down a
non-load-bearing wall, paint over it, move it, replace it with
glass. Touch a load-bearing wall and the roof comes down. The
distinction isn't about which wall is *prettier* or more
*expensive* — it's about what happens if the wall is removed.

When I call a claim or a piece of code or a decision
"load-bearing," I mean the same thing: *other things depend on
it*. If it's wrong or if it's gone, the things built on top of it
fail.

## Three shapes it usually takes

**A claim is load-bearing** when an argument depends on it. The
"multi-scale reasoning is simultaneous" phrasing in the first
nanosecond draft was load-bearing for the frame around it — you
pushed on it, it broke, I rebuilt. A claim that can be imprecise
without the argument collapsing isn't load-bearing; one that
can't is.

**A piece of code is load-bearing** when other code relies on its
invariants. `Poly.simplify()` is load-bearing in your polynomial
library — remove it and equality, printing, and substitution all
break. The router dispatch in Gopher is load-bearing. A blog
post's CSS usually isn't.

**A decision is load-bearing** when subsequent decisions were
made on its basis. Choosing Elm for new UI was load-bearing the
moment LynRummy started porting. A choice nothing depends on yet
— a file's name, a default flag — can be flipped cheaply.

## Why the distinction pays

Naming load-bearing elements is how you decide where to put
effort. You can be loose with ornamental things (rewrite, rip
out, rewrite again) and careful with load-bearing ones. Most of
"rip features fearlessly" applies to the *non*-load-bearing
layer; the load-bearing layer is where the
fearlessness-from-confidence asset-preservation checklist earns
its rent.

Three siblings worth distinguishing:

- **Ornamental:** present, but nothing depends on it.
- **Vestigial:** used to be load-bearing, isn't anymore. Should
  be removed, since its presence misleads readers into treating
  it as still load-bearing.
- **Speculative scaffolding:** not load-bearing yet, put in place
  anticipating future dependence. Often becomes dead code.

## In our own process

The `check_memory.py` script becomes load-bearing the moment we
trust a session start to it. If the hook fails silently, we're
worse off than before we wired it, because we *think* we have the
invariant and we don't. That's a general property of load-bearing
safety infrastructure — its value goes negative if it's wrong, so
verification matters more for it than for the same effort spent
elsewhere.

When I flag something as load-bearing mid-discussion, I'm asking
us to slow down on that element. Not because it's the most
interesting — often it isn't — but because its correctness is
where the downstream economy lives.

— C.

---

**Next →** [Phase, Not Motion](phase_not_motion.md)
