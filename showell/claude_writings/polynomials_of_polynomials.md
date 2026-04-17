# Polynomials of Polynomials

*Written 2026-04-16. My voice. Tangent, long-form, by request.*

**← Prev:** [Human-Factor Arithmetic](human_factor_arithmetic.md)

---

You asked for a longer piece on the `polynomial` project, knowing
it's a side road, and I'm happy to take one. It's the kind of
project I'd recommend a mid-career programmer read cover-to-cover
on a quiet weekend, because almost every engineering move in it
is a small-and-honest version of something that gets overbuilt
elsewhere. The 858-line `poly.py` is a complete symbolic-algebra
library. It does real work. It has a tight scope. It is faithful
to its mathematical substrate. And the phrase you used for its
central move — *polynomials of polynomials* — is a better name
than "substitution" for what's actually happening.

I want to walk through the whole thing: the domain, the data
structures, the canonicalization pass, the operator-overloading
trick, the `Math` plugin, the composition mechanism, and the
cross-representation bridge that makes the whole thing
self-auditing. Then I want to say why it's a worthwhile artifact
even though nobody else is building on it, and how it sits inside
a pattern that keeps recurring across your work.

## The universe you chose

A lot of what makes this library good is what you *didn't*
build. The readme is candid about the scope: no calculus, no
zero-finding, no factoring, no infinite polynomials, no floats,
no complex numbers, no negative or fractional exponents, no
tricks for large computations. What's left is a very small,
closed universe: polynomials with non-negative integer exponents,
over some commutative ring (integers, fractions, or modular
arithmetic by default). That universe has three properties that
make the engineering clean.

**Closure.** Add two polynomials, you get a polynomial.
Multiply two polynomials, you get a polynomial. Substitute a
polynomial into another polynomial, you get a polynomial. There
is no operation in the scope that produces anything outside the
scope. Every function you write has the same return type. The
type system does most of the thinking for you.

**Canonicalization.** Every polynomial has a unique normal
form: sorted terms, merged like terms, zero terms removed. Once
you can compute that normal form, equality becomes a simple
string comparison, and the whole library's correctness is
anchored to one small function.

**Enumerability.** Given two polynomials over integers, if
they aren't equal in the canonical sense, there exists some
integer assignment to the variables at which their `eval()`
results differ. You *know this*, because of the structure of
polynomials. You don't have to hope. That means symbolic
equality and numeric equality are tied together by a theorem,
which turns one into a cheap check on the other.

These three properties — closure, canonicalization,
enumerability — are rare. Most domains a programmer works in
have none of them. The domain you picked was chosen with an
engineer's taste for tractability, not a mathematician's love of
generality. You took the biggest piece of algebra that stays
honest, and stopped at the fence.

## Three layers of data

The code has three internal types, stacked cleanly.

`_VarPower` is the atom: a variable name and an exponent.
`(x**4)` is a `_VarPower`. The class is trivial — it exists
mostly to hold two fields and provide a string signature — but
it's a real type, not a tuple, and the code is better for it.
When you need to ask "what variable is this raised to what
power," you have a type that answers that and only that.

`_Term` is a coefficient times a list of `_VarPower`s:
`2*(x**3)*(y**3)` is a `_Term`. A term has a signature (the
sorted `_VarPower` string) which lets you merge "like terms"
during simplification. A term knows how to apply itself to
variable assignments, how to raise itself to an integer
power, how to factorize out a specific variable (this is the
hook for substitution, which I'll come back to).

`Poly` is a list of `_Term`s, with the simplification invariant
that terms are merged, sorted, and non-zero. A polynomial is
*defined* by its canonical list of terms, not by the
construction history that produced it. This is important: two
polynomials built via completely different construction paths
compare equal if they simplify to the same normal form. The
class carries no construction history.

This three-layer split is almost exactly what a mathematician
would draw on a blackboard: monomial-variable, term,
polynomial. The code doesn't invent its own ontology; it
reflects the one in the readme's Wikipedia links. That's why
it reads so cleanly — the data types are already defined by
the mathematics, and the programmer's job was to respect them.

## Canonicalization as the spine

The `simplify()` method is twenty lines. It buckets terms by
signature, sums the coefficients within each bucket, drops
zero-coefficient terms, and returns. That's it. It runs eagerly
on every `Poly` construction.

This is the most important method in the library, not because
it's complex but because it's the thing that makes the rest of
the library's claims true. Without canonicalization:

- Equality would be impossible to define. Is `x + 1` equal to
  `1 + x`? To `2*x - x + 1`? To `x + 0 + 1`? All of these can
  be constructed. Without a normal form, you'd need a theorem-
  prover to check equivalence.
- String representation would be unstable. Printing the same
  polynomial twice might produce different text.
- Every downstream operation would have to re-check whether its
  output was really a simplified polynomial or a disguised one.

With canonicalization done eagerly on construction, all those
concerns go away. Every `Poly` in the wild is already in normal
form. Equality is structural. Printing is deterministic. And —
crucially — operations like substitution can trust that their
inputs are clean and need only produce clean outputs.

This is a pattern I'd name and put in a mental file labeled
"engineering moves that pay for themselves." Canonicalize
eagerly. Make invariants true at construction, not later.
Accept the up-front cost to make the rest of the system simpler.
The readme even mentions the trade-off: "it is somewhat
expensive to construct a `Poly` object, but then all subsequent
calls to `eval()` are quicker." That's an honest statement of the
deal.

## Operator overloading, earning its keep

Python's dunder methods (`__add__`, `__mul__`, `__pow__`, `__eq__`,
`__radd__`, `__rmul__`, `__sub__`, `__rsub__`, `__neg__`) let you
write `(x + 1) * (x - 1)` instead of `Poly.multiply(Poly.add(x,
Poly.constant(1)), Poly.subtract(x, Poly.constant(1)))`. This
is a purely syntactic feature, but it's doing a lot of work here.

Two observations.

First, it's earning its keep *because the domain supports it*.
Polynomials already have `+`, `*`, `**`, unary negation, and
equality as mathematical operations, with well-defined
semantics. Python's operators are being mapped onto pre-existing
mathematical operators, not being reused for something novel.
When operator overloading is abused — say, using `*` for
something that isn't a multiplication — code gets worse. Here
the alignment is perfect; every overloaded operator means what a
reader would expect.

Second, `__radd__` and `__rmul__` solve a real problem: they let
you write `3 * x` as well as `x * 3`. Without them, mixing
integers and `Poly`s on the left/right of operators would fail
when Python couldn't find a method on the integer. Having both
the forward and reverse methods means the Poly class absorbs the
integer into itself at operator time, regardless of argument
order. That's a small piece of plumbing that's easy to skip and
gives a bad API when skipped. Your code does it.

The overloaded `__eq__` is worth singling out. It's structural
equality on canonical forms. Two polynomials are equal iff their
terms, after simplification, match exactly. Because
canonicalization is eager, `__eq__` is effectively a list
comparison. This also means `==` between a `Poly` and an `int`
works correctly — the integer gets wrapped into a constant
polynomial first.

## The `Math` plugin — pluggable scalars

The library supports integers, fractions, and modular
arithmetic out of the box, and `set_math()` is the hook for
swapping in a custom scalar type. The contract is a handful of
operations: `add`, `mul`, `power`, `negate`, `coeff_str`, plus
`zero`, `one`, and `value_type`.

That short list is — if you squint — the interface for a
commutative ring with a multiplicative identity. The library
isn't quite claiming to work over arbitrary commutative rings;
it's claiming to work over anything that *behaves* like a
commutative ring for the operations it uses. The distinction
matters because it means the library doesn't need to verify
ring axioms — it just trusts the plugin. If you hand it
something that doesn't actually commute, you'll get subtly
wrong answers. The abstraction is usable, not policed.

Three plugins ship. `IntegerMath` is just integer arithmetic.
`FractionMath` uses Python's `fractions.Fraction` for exact
rational arithmetic — a nice touch, because polynomials over
rationals are a genuinely useful target for students. And
`ModulusMath` does arithmetic modulo some prime (or any
positive integer). That last one is the interesting case,
because arithmetic in Z/pZ for prime p is a field, and
polynomials over fields behave very specifically — they factor,
they have well-defined degrees, they admit the Chinese Remainder
Theorem, they're the substrate for a lot of cryptography. A
student who reaches for `ModulusMath` is being nudged toward
abstract algebra in a way that polynomials over integers would
not nudge them.

This is a subtle pedagogical move embedded in the library.
The three plugins shipped aren't arbitrary; they're a progression
from the familiar (integers) through the small-extension
(fractions) to the conceptually new (modular arithmetic). Read
in order, they teach something about what a ring *is*.

The plugin mechanism itself is a global — `set_math` mutates a
module-level variable. This is the one place in the library I'd
call "pragmatic rather than elegant." A cleaner design would
parameterize `Poly` on its math type at construction. But the
global approach is simpler for a one-person hobby project, and
it keeps the API free of threading the math type through every
call. The readme is honest about the intended scope, and this
choice fits that scope.

## Polynomials of polynomials

Now the central move. The `substitute(var_name, var_poly)`
method on `Poly` takes a variable name and a polynomial, and
replaces every occurrence of that variable with the given
polynomial, producing a new polynomial. This is function
composition: if `g(x) = x^2 + 3`, then `g.substitute("x", f)`
is `g ∘ f`.

The implementation is twelve lines. For each term in `self`,
factor out the substituted variable (call it `x`) — the term
`3*x^2*y` factors as `(3*y) * x^2`. The non-x part is still a
term; the x-power is an integer. Then you multiply the non-x
part by `(var_poly)^k`, where `k` is the x-power you extracted.
Sum the results across all terms. That's the whole substitution
algorithm.

Two things make this work.

First: *polynomials are closed under substitution*. You can
substitute anything in the polynomial universe into anything
else in the polynomial universe and stay in the universe. This
is why the implementation can be twelve lines — you never have
to escape the type. Compare with, say, substituting one
trigonometric expression into another, where you might leave
the domain you started in. Polynomials are self-contained in a
way that most function spaces aren't.

Second: *exponentiation reduces to repeated multiplication*,
and you've already implemented multiplication. So
`(var_poly)^k` isn't a separate operation; it's
`var_poly * var_poly * ... * var_poly`. And multiplication is
handled by `multiply_polys`, which is itself a simple double
loop over terms. The substitution operation is built out of
operations you already had. This is the compounding that
happens when you get the primitives right: the complex-looking
operation (composition) turns out to be nearly free.

"Polynomials of polynomials" is the right name for what you
built. You're treating polynomials as both the *ambient space*
and the *functions operating on that space* simultaneously. The
same type serves as values and as mappings. That's a small
instance of the same self-referential structure that makes
combinatory logic and lambda calculus work — terms that are both
data and programs. Your version stays on a tiny, tractable
island of that bigger idea, but it's the same island.

## Symbolic vs numeric — the built-in bridge

I want to spend time on one claim the readme is careful about:
*two polynomials are equal under `==` if and only if their
`eval()` results agree for all integer assignments.* The "only
if" direction is provable and you believe it. The "if" direction
— that agreeing on all integer inputs implies identical canonical
form — depends on the field or ring being infinite (or at least
large enough); it's true for integers and fractions.

Why this matters: it means the library has *two independent
representations of every polynomial*. The symbolic one (the
canonical term list) and the numeric one (the function from
variable-assignment to value). These two representations are
locked together by mathematics. If you ever doubted whether your
canonicalization code was correct, you could generate random
polynomials, compute them symbolically, evaluate them at random
integer points, and cross-check. Two different engines, one
shared truth, a bridge that you didn't have to build because
polynomial theory built it for you.

This is exactly the shape you call *enumerate-and-bridge*. Two
representations of the same object, forced to agree. Disagreement
is a bug you can automatically detect. The `polynomial` library
has this property built into its domain — it didn't need a
second implementation, just the built-in `eval()` alongside the
symbolic equality, and they were independent enough to
cross-verify. This is the cleanest instance of
enumerate-and-bridge I can point to in your code, and it's
inherited from the mathematics rather than imposed by the
engineer.

The `examples/main.py` file demonstrates the bridge implicitly.
Most of the file consists of `assert_equal(p.eval(...), ...)` and
`assert_str(p, ...)` checks, interleaved. Each assertion tests
one of the two representations against a human-specified ground
truth. Run them both; if either breaks, you know something's
wrong with either symbolic manipulation or evaluation. The test
suite is a cross-check, not a single-axis verifier.

## What you didn't build, and why it matters

The readme's list of non-features is worth reading as a document
in its own right. "No calculus." "No zero-finding." "No
factoring." "No negative exponents." These are principled cuts.
Each one would have pulled the library out of its tractable
universe into something harder.

Calculus, in particular, is an interesting cut. Formal
differentiation of polynomials is *easy* — it's a mechanical
rule, and the result stays in the polynomial domain. But
integration can leave the domain (x^{-1} integrates to a
logarithm), and the readme mentions differentiation as "a great
exercise for students." I think the implied argument is: once
you start adding calculus, you start hinting at a general
symbolic-math library, and users will expect more than you're
willing to maintain. Better to stop cleanly at polynomials and
let SymPy be SymPy.

This is, again, a form of taste. The discipline to stop where
you stopped is what separates a usable small library from a
failed large one. Most hobby math libraries die because their
authors chase generality past the point where they can keep the
internals clean. You cut exactly where the internals start
wanting to spill.

## What reading this project teaches

I'd recommend someone read `polynomial` for five reasons, none
of which are about polynomials per se.

**1. Domain-shaped types.** Your three internal types mirror
the three levels of the mathematical domain. When a programmer
finds themselves inventing their own hierarchy, it's often
because the problem domain doesn't *have* one, or they haven't
found it. Polynomials have one. You used it. The code is
simpler as a result.

**2. Eager canonicalization.** Simplify on construction.
Invariants held at the type level. Equality made structural.
This move shows up in filesystems (normalized paths), URLs
(canonical forms), ASTs (normalized trees), build systems
(deterministic output), and SQL (normal forms). Every domain
that eventually wants equality comparison ends up wanting a
canonicalization pass. Worth internalizing early.

**3. Operator overloading that earns its keep.** When the
domain has pre-existing operators, Python's overloading
mechanism carries real weight. When the domain doesn't,
overloading is an anti-pattern. The library is a clean case of
the former. Studying which operators it overloaded and which it
didn't (no `<` ordering, for instance, since polynomials aren't
totally ordered in a meaningful way) is a short lesson in
operator discipline.

**4. Pluggable primitives.** The `Math` plugin interface is
the minimum set of operations that makes polynomials well-defined.
If you wanted to extend the library to polynomials over, say,
matrices (where commutativity fails), you'd discover through the
plugin interface which operations the library actually relies
on, and you'd learn why matrix polynomials are a genuinely
different object. The plugin is a teaching tool disguised as an
extension hook.

**5. Self-auditing via independent representations.** The
symbolic-vs-numeric bridge is the most broadly useful idea in
the library. Any time you can compute a thing two independent
ways and compare, you have a self-auditing system. The
`polynomial` library got this almost for free because the domain
has it built in. But the template — two engines, one truth,
cross-checked — transfers to places that don't have it for
free. It's worth looking for opportunities to manufacture this
shape in other domains.

## Where this sits among your other work

You've built a lot of things with this shape. The LynRummy
referee triple (three independent implementations forced to
agree). `fixturegen` (generator vs. parser, forced to roundtrip).
The Wacky VM polynomial-vs-simulator cross-check. Every time
you build a small self-contained universe with two ways in and
compare, you're using the same engineering instinct that made
the `polynomial` library land cleanly.

What the `polynomial` library adds to that catalog is *the
cleanest case*. The domain was already closed, already
canonicalizable, already bridge-able. You didn't have to
manufacture the structure; you just had to respect it. That
makes the library a good reference point for the pattern. When
you want to explain enumerate-and-bridge to someone — a student,
a colleague, me — pointing at this library and saying "this,
but do it for your domain" is a shorter path than any essay.

## Close

One of the quietly valuable things about `polynomial` is that
it still works. It has no active dependencies that can rot. No
upstream libraries that can break it. No web services. No
filesystem assumptions beyond "this is a Python package." If
you came back to it in 2036, after a decade of not touching it,
you'd clone the repo, run `examples/main.py`, and it would
still print the same assertions green. That kind of durability
is rare and worth noticing. It comes from the decision, made
early, to stay inside a closed mathematical universe and accept
the scope that universe provides.

This is the inverse of the usual critique of small libraries
("but it's limited"). Limited is the *feature*. The domain sets
the scope; the scope is honest; the code stays faithful to the
scope; and because the scope is mathematical, it doesn't rot.
Most software rots because its domain isn't mathematics and its
substrate changes. Polynomial math doesn't change. The library
can't become obsolete in the usual way.

If I had to pick one sentence that captures what makes the
project work, it's this: *you picked a universe small enough
to be closed, rich enough to be interesting, and grounded enough
to be self-auditing; and you built exactly the library that
universe called for, and then you stopped*. That's a rarer skill
than library-building in general. It's the skill of knowing
when to stop.

— C.

---

**Next →** [Concentration, Not Pressure](concentration_not_pressure.md)
