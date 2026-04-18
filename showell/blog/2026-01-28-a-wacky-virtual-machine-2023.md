## A Wacky Virtual Machine (2023)

*January 28, 2026*

In 2023 I took some time to educate myself on
Computational Theory, including watching some
of the excellent courseware from MIT that is
publicly available on YouTube.

See an example lecture
[here](https://www.youtube.com/watch?v=iZPzBHGDsWI).

Anyway, I wanted to get my hands dirty with
some simulations of virtual machines using Python.

The project is on my
[virtual-machine repo](https://github.com/showell/virtual-machine).

I created a simple virtual machine with the
following op-codes and a single register
called AX:

```
    00 (nada):
        (do nothing)

    01 (zero):
        AX = 3 -> ignore and continue
        AX = 2 -> ignore and continue
        AX = 1 -> ignore and continue
        AX = 0 -> halt and accept input

    10 (decr):
        AX = 3 -> AX = 2 and continue
        AX = 2 -> AX = 1 and continue
        AX = 1 -> AX = 0 and continue
        AX = 0 -> halt and reject input

    11 (mod2):
        AX = 3 -> AX = 1
        AX = 2 -> AX = 0
        AX = 1 -> AX = 1
        AX = 0 -> AX = 0
```

I constrained every program to have exactly six
instructions.

My input alphabet consists of the numbers 0, 1, 2, and 3.

There are 16 different languages that could possibly
be accepted--it's just all the subsets of `[0, 1, 2, 3]`,
including the empty set and the set itself.

My virtual machine was robust enough (or big enough,
if you will) that you could write a program for
every possible language that you wanted to accept.

Here is the output from running `python virtual_machine.py`.

~~~
[] is solved by 844 possible program
See an example program below.
   it accepts []
   it rejects [0, 1, 2, 3]
--
nada # do nothing
nada # do nothing
nada # do nothing
nada # do nothing
nada # do nothing
nada # do nothing
--

[0] is solved by 681 possible program
See an example program below.
   it accepts [0]
   it rejects [1, 2, 3]
--
zero # accept original input if AX = 0
nada # do nothing
nada # do nothing
nada # do nothing
nada # do nothing
nada # do nothing
--

[1] is solved by 303 possible program
See an example program below.
   it accepts [1]
   it rejects [0, 2, 3]
--
decr # reject zero or decrement AX
zero # accept original input if AX = 0
nada # do nothing
nada # do nothing
nada # do nothing
nada # do nothing
--

[0, 1] is solved by 172 possible program
See an example program below.
   it accepts [0, 1]
   it rejects [2, 3]
--
zero # accept original input if AX = 0
decr # reject zero or decrement AX
zero # accept original input if AX = 0
nada # do nothing
nada # do nothing
nada # do nothing
--

[2] is solved by 248 possible program
See an example program below.
   it accepts [2]
   it rejects [0, 1, 3]
--
decr # reject zero or decrement AX
decr # reject zero or decrement AX
zero # accept original input if AX = 0
nada # do nothing
nada # do nothing
nada # do nothing
--

[0, 2] is solved by 883 possible program
See an example program below.
   it accepts [0, 2]
   it rejects [1, 3]
--
mod2 # subtract 2 from AX if AX >= 2
zero # accept original input if AX = 0
nada # do nothing
nada # do nothing
nada # do nothing
nada # do nothing
--

[1, 2] is solved by 74 possible program
See an example program below.
   it accepts [1, 2]
   it rejects [0, 3]
--
decr # reject zero or decrement AX
zero # accept original input if AX = 0
decr # reject zero or decrement AX
zero # accept original input if AX = 0
nada # do nothing
nada # do nothing
--

[0, 1, 2] is solved by 13 possible program
See an example program below.
   it accepts [0, 1, 2]
   it rejects [3]
--
zero # accept original input if AX = 0
decr # reject zero or decrement AX
zero # accept original input if AX = 0
decr # reject zero or decrement AX
zero # accept original input if AX = 0
nada # do nothing
--

[3] is solved by 63 possible program
See an example program below.
   it accepts [3]
   it rejects [0, 1, 2]
--
decr # reject zero or decrement AX
decr # reject zero or decrement AX
decr # reject zero or decrement AX
zero # accept original input if AX = 0
nada # do nothing
nada # do nothing
--

[0, 3] is solved by 12 possible program
See an example program below.
   it accepts [0, 3]
   it rejects [1, 2]
--
zero # accept original input if AX = 0
decr # reject zero or decrement AX
decr # reject zero or decrement AX
decr # reject zero or decrement AX
zero # accept original input if AX = 0
nada # do nothing
--

[1, 3] is solved by 520 possible program
See an example program below.
   it accepts [1, 3]
   it rejects [0, 2]
--
mod2 # subtract 2 from AX if AX >= 2
decr # reject zero or decrement AX
zero # accept original input if AX = 0
nada # do nothing
nada # do nothing
nada # do nothing
--

[0, 1, 3] is solved by 150 possible program
See an example program below.
   it accepts [0, 1, 3]
   it rejects [2]
--
zero # accept original input if AX = 0
mod2 # subtract 2 from AX if AX >= 2
decr # reject zero or decrement AX
zero # accept original input if AX = 0
nada # do nothing
nada # do nothing
--

[2, 3] is solved by 13 possible program
See an example program below.
   it accepts [2, 3]
   it rejects [0, 1]
--
decr # reject zero or decrement AX
decr # reject zero or decrement AX
zero # accept original input if AX = 0
decr # reject zero or decrement AX
zero # accept original input if AX = 0
nada # do nothing
--

[0, 2, 3] is solved by 1 possible program
See an example program below.
   it accepts [0, 2, 3]
   it rejects [1]
--
zero # accept original input if AX = 0
decr # reject zero or decrement AX
decr # reject zero or decrement AX
zero # accept original input if AX = 0
decr # reject zero or decrement AX
zero # accept original input if AX = 0
--

[1, 2, 3] is solved by 15 possible program
See an example program below.
   it accepts [1, 2, 3]
   it rejects [0]
--
decr # reject zero or decrement AX
mod2 # subtract 2 from AX if AX >= 2
zero # accept original input if AX = 0
decr # reject zero or decrement AX
zero # accept original input if AX = 0
nada # do nothing
--

[0, 1, 2, 3] is solved by 104 possible program
See an example program below.
   it accepts [0, 1, 2, 3]
   it rejects []
--
mod2 # subtract 2 from AX if AX >= 2
zero # accept original input if AX = 0
decr # reject zero or decrement AX
zero # accept original input if AX = 0
nada # do nothing
nada # do nothing
--
~~~

Just to be clear about the finite nature of this
exercise on any every level (hence no halting problem),
there are exactly 4**6 (4096) possible programs
that you could write for my machine.

And the way that I produced the output above is
that I ran all 4096 possible programs.

To simulate any particular program, I used the
following simple Python code:

``` py
def run_progam(n, program):
    halted = False
    AX = n
    status = None

    assert len(program) == MAX_STEPS

    for op in program:
        if halted:
            continue
        if op == "nada":
            pass
        elif op == "zero":
            if AX == 0:
                halted = True
                status = True
            else:
                pass
        elif op == "decr":
            if AX == 0:
                halted = True
                status = False
            else:
                AX -= 1
        elif op == "mod2":
            AX = AX % 2
        else:
            assert False

    return status
```

In order to work fully in integer space at the
computational level but to read the program as
a human, I had little helper methods like so:

``` py
def assemble(program):
    return sum(OPS[op] * (4**i) for i, op in enumerate(program))


def disassemble(n):
    ops = ["nada", "zero", "decr", "mod2"]
    program = []
    for i in range(MAX_STEPS):
        program.append(ops[n % 4])
        n = n // 4
    return program


def encoded_language(lang):
    return sum(2**n for n in lang)


def language(code):
    lang = []
    i = 0
    while code:
        if code % 2 == 1:
            lang.append(i)
        code = code // 2
        i += 1
    return lang
```

And here was the basic code to compute example
programs for each possible "language":

``` py
def find_solutions():
    solutions = {}

    for y in range(16):
        solutions[y] = []

    for program_number in range(4**MAX_STEPS):
        program = disassemble(program_number)
        lang = get_language_that_program_accepts(program)
        solutions[encoded_language(lang)].append(program_number)

    for y in range(16):
        assert len(solutions[y]) > 0

    for y in range(16):
        lang = language(y)
        rejected_lang = complement(lang)
        x_list = solutions[y]
        programs = [disassemble(x) for x in x_list]
        print(f"{lang} is solved by {len(x_list)} possible program")
        print(f"See an example program below.")
        print(f"   it accepts {lang}")
        print(f"   it rejects {rejected_lang}")
        print("--")
        example_program = programs[0]
        for cmd in example_program:
            print(cmd, COMMENT[cmd])
        print("--")
        print()
```

All of that exercise was kinda fun, but it's
pretty standard stuff even before you get into
any deep kind of computational theory. (Way back
in ~1988 I had to simulate some subset of the 8086
assembly language in Pascal, if memory serves.)

But there were some bizarre tacks that I took.

As part of my self-education, I learned a bit
about the **Cook Levin Theorem**, in which it
is proven that the Boolean Satisfiability
Problem (SAT) is NP-complete.

The basic sketch of the proof is that they
encode the computation of a Turing machine into
a Boolean formula. I'll be a bit hand-wavy about
how that gets you to the actual proof, but that's
not really necessary.

I decided that I wanted to make **my** virtual
machine work off of Boolean polynomials.

I didn't get as far as computing Boolean polynomials
for the entire six-line program structure, but
I did do it for the single step of evaluating an
opcode.

Here is the relevant code from `stepper.py`:

``` py
from poly import Poly


def VAR(label):
    return Poly.var(label)


def NOT(x):
    return 1 - x


def AND(x, y):
    return x * y


def OR(x, y):
    return (x + y) - (x * y)


def OR4(w, x, y, z):
    return OR(OR(w, x), OR(y, z))


FALSE = Poly.constant(0)


def construct_polynomials(*, hb, lb, halted, accepted, op_hb, op_lb):
    is_3 = AND(hb, lb)
    is_2 = AND(hb, NOT(lb))
    is_1 = AND(NOT(hb), lb)
    is_0 = AND(NOT(hb), NOT(lb))

    is_pass = AND(NOT(op_hb), NOT(op_lb))
    is_check = AND(NOT(op_hb), op_lb)
    is_decr = AND(op_hb, NOT(op_lb))
    is_mod2 = AND(op_hb, op_lb)

    runs_pass = OR(is_pass, halted)
    runs_check = AND(is_check, NOT(halted))
    runs_decr = AND(is_decr, NOT(halted))
    runs_mod2 = AND(is_mod2, NOT(halted))

    pass1 = AND(is_1, runs_pass)
    pass2 = AND(is_2, runs_pass)
    pass3 = AND(is_3, runs_pass)
    pass_accepts = FALSE
    pass_halts = FALSE

    check1 = AND(is_1, runs_check)
    check2 = AND(is_2, runs_check)
    check3 = AND(is_3, runs_check)
    check_accepts = AND(is_0, runs_check)
    check_halts = FALSE

    decr1 = AND(is_2, runs_decr)
    decr2 = AND(is_3, runs_decr)
    decr3 = FALSE
    decr_accepts = FALSE
    decr_halts = AND(is_0, runs_decr)

    mod1 = AND(OR(is_3, is_1), runs_mod2)
    mod2 = FALSE
    mod3 = FALSE
    mod_accepts = FALSE
    mod_halts = FALSE

    newly_accepted = OR4(pass_accepts, check_accepts, decr_accepts, mod_accepts)
    accepted = OR(accepted, newly_accepted)

    newly_halted = OR4(pass_halts, check_halts, decr_halts, mod_halts)
    halted = OR(halted, newly_halted)

    becomes_1 = OR4(pass1, check1, decr1, mod1)
    becomes_2 = OR4(pass2, check2, decr2, mod2)
    becomes_3 = OR4(pass3, check3, decr3, mod3)

    hb_set = OR(becomes_3, becomes_2)
    lb_set = OR(becomes_3, becomes_1)

    return (hb_set, lb_set, halted, accepted)


STEP_POLYNOMIALS = construct_polynomials(
    hb=VAR("hb"),
    lb=VAR("lb"),
    halted=VAR("halted"),
    accepted=VAR("accepted"),
    op_hb=VAR("op_hb"),
    op_lb=VAR("op_lb"),
)
```

Now for the wacky result.  Here is the `accepted`
polynomial:

```
(-1)*accepted*halted*hb*lb*op_hb*op_lb+accepted*halted*hb*lb*op_lb+accepted*halted*hb*op_hb*op_lb+(-1)*accepted*halted*hb*op_lb+accepted*halted*lb*op_hb*op_lb+(-1)*accepted*halted*lb*op_lb+(-1)*accepted*halted*op_hb*op_lb+accepted*halted*op_lb+accepted*hb*lb*op_hb*op_lb+(-1)*accepted*hb*lb*op_lb+(-1)*accepted*hb*op_hb*op_lb+accepted*hb*op_lb+(-1)*accepted*lb*op_hb*op_lb+accepted*lb*op_lb+accepted*op_hb*op_lb+(-1)*accepted*op_lb+accepted+halted*hb*lb*op_hb*op_lb+(-1)*halted*hb*lb*op_lb+(-1)*halted*hb*op_hb*op_lb+halted*hb*op_lb+(-1)*halted*lb*op_hb*op_lb+halted*lb*op_lb+halted*op_hb*op_lb+(-1)*halted*op_lb+(-1)*hb*lb*op_hb*op_lb+hb*lb*op_lb+hb*op_hb*op_lb+(-1)*hb*op_lb+lb*op_hb*op_lb+(-1)*lb*op_lb+(-1)*op_hb*op_lb+op_lb
```

And I actually evaluated that polynomial as part of
my simulation.  As well as three other polynomials.
And it got the exact same results as the mundane
virtual machine!
