# A Cook-Levin in Miniature

*Written 2026-04-16. My voice. By request — a tangent companion to Polynomials of Polynomials.*

**← Prev:** [Concentration, Not Pressure](concentration_not_pressure.md)

---

You asked me to write on your "Cook-Levin thingy" and confessed
the project is rusty in your head. So the first job is to find
it, remind you what you built, and then walk through why it's a
small jewel.

The project lives at `~/showell_repos/virtual-machine/`. About
1,200 lines of Python, three years old, no active dependencies
other than your own `polynomial` library. It is a concrete,
runnable, fully-enumerable demonstration of the idea behind the
Cook-Levin theorem — the theorem that every problem in NP can
be reduced to Boolean satisfiability, proved in the early 1970s
by Stephen Cook and (independently) Leonid Levin. The theorem
is one of the load-bearing results of theoretical computer
science. It is also notoriously abstract in the usual
presentations: you're walking through encodings of Turing
machine tapes as conjunctions of variables over polynomially
many clauses, and if you weren't raised in that vocabulary it
lands as noise.

Your project does not teach the full theorem. What it does is
better for most readers: it builds a concrete, tiny universe
where you can *watch the construction happen*, evaluate both
halves of it, and cross-check them. That's an act of compression
— taking the essential structural move of the Cook-Levin proof
and demonstrating it on a scale small enough to fit in your
head. Which is exactly what a didactic artifact should do.

## What you built, in one paragraph

You defined a tiny virtual machine. It has a single 2-bit
register `AX` (values 0–3), four opcodes, and programs of
exactly six instructions. Any program recognizes some subset of
`{0, 1, 2, 3}` — its "language." There are 4⁶ = 4,096 possible
programs and 2⁴ = 16 possible languages. Then you wrote two
independent implementations of the VM's single-step function: a
direct Python interpreter, and a *polynomial stepper* that
encodes every state transition as Boolean algebra lifted into
arithmetic. You enumerated every program, ran both simulators,
and confirmed they agree on every input. That's the project.

Let me unpack why each piece matters.

## The VM specification — finite by design

The first design choice I want to call out is *finiteness*. Your
VM is not a Turing machine; it's a strict subset of what a
Turing machine can do. The register is 2 bits. Programs are
exactly six instructions long. Inputs are single numbers in
`{0, 1, 2, 3}`. Every possible (program, input) pair can be
enumerated in a short loop.

This is deliberate. A real Cook-Levin proof has to handle a
Turing machine with unbounded tape and arbitrary runtime; the
construction has to quantify over "polynomial time" and
"polynomial space," and the formula it produces has polynomial
size in those bounds. For a teaching artifact, that's all
overhead. You stripped it to a scale where the formula is
finite, the input space is finite, the program space is finite,
and you can literally print every one.

The price you pay is that the VM is less expressive — it can
recognize only languages over a 4-element alphabet, using
programs of fixed length. The payoff is that every claim you
make about the construction can be *verified by enumeration*,
not just argued by proof. And verification-by-enumeration is a
much more persuasive teaching tool than symbolic argument when
the target audience hasn't yet built the intuition.

The four opcodes are `nada` (do nothing), `zero` (accept if AX
is 0, otherwise do nothing), `decr` (decrement AX, or reject if
AX is already 0), and `mod2` (replace AX with AX mod 2). With
those four and six steps, you can build programs for every one
of the 16 possible languages. You verified this by brute force
in `find_solutions`, which actually prints out an example
program for each of the 16.

That `find_solutions` is worth staring at for a moment. It's a
constructive existence proof: "for every language over `{0,1,2,3}`,
here is a program in this VM that recognizes it." The proof is
the loop. It doesn't argue; it demonstrates. I'll come back to
why that shape matters.

## The polynomial stepper — where Cook-Levin actually happens

The piece that earns the "Cook-Levin" label is `stepper.py`.
It's 160 lines. The move it makes is this:

**Every Boolean value is a polynomial variable that takes the
value 0 or 1. Every Boolean operation becomes an arithmetic
operation that preserves that property.**

You define:

```python
def NOT(x):  return 1 - x
def AND(x, y):  return x * y
def OR(x, y):  return (x + y) - (x * y)
```

Check: if `x` and `y` are each in `{0, 1}`, then `NOT(x) =
1 - x` is also in `{0, 1}`. `AND(x, y) = x*y` is `1` iff both
are `1`, else `0`. `OR(x, y) = x + y - x*y` is `1` iff at
least one is `1`, because either the sum is 1 (one of them is
1, the other 0, `x*y` is 0) or the sum is 2 (both are 1,
`x*y` is 1, so `x+y-x*y = 1`). The operations are exact.

This is the **algebraization trick**. Booleans don't naturally
live inside polynomial rings over integers; but `{0, 1}`
*happens to be* a subset that's closed under these specific
formulas. Once you commit to this encoding, every Boolean
expression becomes a polynomial, and every polynomial built from
0/1-valued inputs produces a 0/1 output. You have lifted
Boolean logic into polynomial arithmetic without leaving the
ring of integer polynomials.

The Cook-Levin construction wants to turn computation into
Boolean formulas. Yours goes one step further: it turns
computation into *polynomials*, which are a slightly richer
substrate that happens to contain Boolean logic as a subset.
This is why your own `Poly` class from the polynomial project
is the right tool for the job. You can build a polynomial
symbolically, apply variable substitutions, evaluate with
integer inputs — and because the polynomials encode Boolean
operations, integer evaluation with 0/1 inputs gives you
Boolean results.

## The step function as a polynomial

Now the central move. The VM's step function — "given current
state and current opcode, what's the next state?" — is encoded
as a symbolic polynomial expression.

Your `construct_polynomials` function takes six variables:
`hb`, `lb` (the high and low bits of AX), `halted`, `accepted`
(the control flags), and `op_hb`, `op_lb` (the two bits of the
opcode). These are all polynomial variables — `Poly.var("hb")`
etc. They're each intended to be 0 or 1 at evaluation time.

Inside the function, you build up polynomials that represent
the state-transition logic:

```python
is_3 = AND(hb, lb)
is_2 = AND(hb, NOT(lb))
is_1 = AND(NOT(hb), lb)
is_0 = AND(NOT(hb), NOT(lb))

is_pass = AND(NOT(op_hb), NOT(op_lb))
is_check = AND(NOT(op_hb), op_lb)
# ...and so on
```

Each of these is a polynomial expression in the six input
variables that evaluates to `1` exactly when the named
condition holds. `is_3` is `hb * lb` — it's 1 only when both
high and low bits are 1, i.e. `AX = 3`. The whole function is a
chain of these conjunctions and disjunctions, building up to
four output polynomials: `hb_set`, `lb_set`, `halted`,
`accepted` for the next state.

Critically, this construction happens **once, symbolically**.
The line

```python
STEP_POLYNOMIALS = construct_polynomials(hb=VAR("hb"), ...)
```

runs at module import time and produces four polynomials in six
variables. After that, stepping the VM is a matter of
evaluating those polynomials at concrete 0/1 values. The
symbolic work is done; only evaluation happens per step.

This is the Cook-Levin shape in miniature: **computation
replaced by polynomial evaluation**. A Turing-machine proof
would build a much larger polynomial (or CNF formula)
representing a full computation history. Yours builds a
per-step one and evaluates it in a loop. The difference is
scale, not kind.

## Enumerate-and-bridge, again

Here's where the project becomes more than a Cook-Levin demo.
You have *two complete simulators* of the same VM:

1. `virtual_machine.run_progam` — direct Python interpreter. Reads
   opcodes, branches on them, mutates state.
2. `stepper.test_with_stepper` — polynomial stepper. Feeds the
   current state into the symbolic polynomials, evaluates them,
   reads the new state.

They're written in completely different styles. The interpreter
is imperative and reads like plain pseudocode. The stepper is
algebraic and reads like a compiled logic circuit. The only
thing they share is the VM specification.

And you cross-check them. In `find_solutions`, after enumerating
every program and computing its language via the interpreter,
you also run every program on every input through the stepper
and assert the results match:

```python
for i in range(4):
    accepted = stepper.test_with_stepper(example_program, i)
    assert accepted == (i in lang)
```

This is enumerate-and-bridge, doing exactly the job it was made
for. Two independent representations of the same semantics,
forced to agree. If your algebraization had a bug — say, the
`OR` formula was wrong for one edge case — this test would
catch it. If the interpreter had a bug, this test would catch
it. If both had the *same* bug, you'd need a third oracle, but
the architectures are so different that a shared bug is
extraordinarily unlikely.

The broader template: **write two maximally-different
implementations of your domain, then cross-check**. You do this
so often (LynRummy referee triple, `fixturegen`, `polynomial`
library's symbolic-vs-numeric bridge) that it has earned its
name in the glossary. The Cook-Levin miniature is another
clean instance, with the unusual twist that one of the two
implementations is *algebra*, which most programmers don't
reach for as a simulator technology.

## Why it's a good teaching artifact

A student who reads this repo in order — readme, then
`virtual_machine.py`, then `stepper.py` — gets a lot for free.

**They see what a VM is.** The direct interpreter is maybe 30
lines of logic. It's the smallest complete interpreter they can
encounter without it being a joke. The VM is expressive enough
to recognize every subset of a 4-element alphabet, which means
they can think about "languages" and "recognizers" with a
concrete register of programs in hand.

**They see brute-force enumeration as a proof technique.** The
`find_solutions` function *proves* that every language is
recognizable by constructing an example. Proof by
construction, mechanized. For a student who has only ever seen
proofs as symbolic arguments, this is a different kind of
mathematical object, and worth meeting.

**They see the algebraization trick.** Most introductions to
Cook-Levin dive straight into Boolean clauses and SAT. Yours
introduces the richer idea that Boolean logic *embeds into*
polynomial arithmetic, and that once you're in the polynomial
world you have all the usual algebraic tools available. The
student who has read both your `polynomial` library and this
repo now has a concrete picture of why "algebraic" methods show
up in complexity theory.

**They see cross-checking between radically different
architectures.** This is the most broadly transferable lesson.
The interpreter and the polynomial stepper are both *right*,
and they're right in different ways — one by direct execution,
one by algebraic evaluation. When they agree, you have a
strong reason to trust both. This is a template that transfers
to almost any domain where you can find two independent
reductions of the same problem.

**They see what "Cook-Levin" actually says, stripped of the
usual formalism.** The theorem asserts that computation can be
encoded as formula satisfaction. You show this by building a
computation-as-polynomial and running it. The abstraction that
made Cook and Levin's proof feel distant collapses into a
concrete thing on disk.

## What it is not, and why that's fine

Your readme doesn't mention any of this teaching framing. The
project is presented as just a small VM with a polynomial
stepper, no fanfare. That's appropriate. The project isn't
*advertising* itself as a Cook-Levin demo; it happens to *be*
one, for a reader who recognizes the shape.

There are things it doesn't do, and the list is worth being
honest about.

- It doesn't construct a single polynomial representing the
  full computation of a program on an input. You could do this
  — compose the step polynomials six times with variable
  renaming — and end up with one polynomial in the initial
  state variables and opcode bits that evaluates to 1 iff the
  program accepts. That's closer to the literal Cook-Levin
  formula. But six-fold composition in your `Poly` class would
  produce a large polynomial, and the project stops before
  going there.

- It doesn't reduce any concrete NP problem to SAT in the
  classical sense. It shows the *technique* that underlies
  such reductions — computation as algebra — but not a
  reduction of, say, Hamiltonian Path to Boolean formulas.

- It doesn't handle nondeterminism. A full Cook-Levin proof
  needs to encode the *existence* of an accepting computation
  path; your machine is deterministic. The next conceptual step
  (which you didn't take) would be to add choice opcodes and
  existential-quantify over their values.

Each of these would be a natural extension. None of them are
present. And the project is better for it, because the thing
that's present is small enough to read in one sitting and
comprehensively verified by enumeration. Pile on the extensions
and you lose both properties.

## The `Poly` connection

This project is also the cleanest evidence that your
`polynomial` library earned its place. The `Poly` class is not
a plaything here — it's doing real work as a symbolic
substrate. Every Boolean expression in `stepper.py` is a `Poly`
instance. The whole step function is one big polynomial
construction that's built once at import time and then
evaluated many times.

Without `Poly`, you'd have needed to either:

- Evaluate all the Boolean formulas eagerly on concrete 0/1
  values (which would defeat the point of having a symbolic
  construction), or
- Invent a lightweight symbolic-expression class inside this
  project, duplicating most of what `Poly` already does.

Using `Poly` means you get canonicalization, equality, and
evaluation for free. When `STEP_POLYNOMIALS` is constructed,
the `Poly` class's eager simplification kicks in and reduces
the expressions to canonical form. When you evaluate, it's
honest integer arithmetic all the way down. Nothing in the
stepper code is reinventing wheels that live in the polynomial
repo.

This is the kind of composition that makes multi-project
libraries worthwhile. The `polynomial` project, read in
isolation, looks like a pedagogical toy. Read together with
`virtual-machine`, it looks like infrastructure — a substrate
that was always going to be used for things like this.
Whichever way you came at it originally, the pair retroactively
justifies the generality of `Poly`.

## A small observation on durability

Like the `polynomial` project, `virtual-machine` has aged well
despite three years of neglect. It depends on Python 3 and your
own `polynomial` library and nothing else. No framework can
break it. No web service can deprecate under it. Run `python
virtual_machine.py` in 2036 and you will see the same 16
languages print out, with the same example programs.

This is a property your projects seem to accumulate
deliberately: close the universe, minimize the substrate, and
the code becomes weather-resistant. The artifact remains what
it was. Most software projects from three years ago are dead or
mutated; yours just sits there, working, ready to be explained
again.

## Close

The "Cook-Levin thingy" is, in my estimate, one of the
sharpest pedagogical artifacts in your portfolio. It doesn't
prove Cook-Levin; it *demonstrates the central move* on a
scale small enough to be fully verified. It combines your
`polynomial` library with a tiny VM to produce something that
reads like a Cook-Levin proof mechanized by a careful engineer.
And it inherits your usual taste: small closed universe,
enumerate-and-bridge architecture, no dependencies that can
rot.

If a student or colleague asked me to recommend a reading that
gives the flavor of NP-completeness proofs without the
formalism, I would point them here before I pointed them at
Sipser. Sipser would teach them the formal structure; your
repo would teach them the *feel* of the central trick, which
is often the harder thing to acquire.

If you ever feel like extending it, the obvious next move is
the six-step composition I mentioned — produce the single
polynomial representing full program execution, then use it as
a static analysis: for what input values does this polynomial
evaluate to 1? That would take the artifact one step closer to
a literal Cook-Levin formula. But it would also blow up the
polynomial size, and the current pedagogical sweet spot would
be lost. Worth considering, not worth rushing.

Thanks for pointing me at it. It was fun to read.

— C.

---

**Next →** [Going Forward: Bridges in Angry Gopher](going_forward_bridges_in_gopher.md)
