## Boolean Satisfiability Problem (SAT)

*January 28, 2026*

One of the most interesting problems in computer science
is whether the Boolean Satisfiability Problem can be
solved in polynomial time.  It's pretty trivial to
verify solutions in polynomial time.  It's also pretty
trivial to solve it in exponential time.

I got interested in this problem when I started watching
MIT Open Courseware in 2023.  I listened to most of
Michael Sipser's lectures in his "Theory of Computation"
class from Fall 2020.

See an example lecture
[here](https://www.youtube.com/watch?v=iZPzBHGDsWI).

Believe me, I did not attempt to solve this problem in
polynomial time. If I had done that and succeeded, this
would be a much longer blog post!

Instead, I used Python to play around with modeling
the simple cases in my
[boolean-algebra repo](https://github.com/showell/boolean-algebra).

The key thing to start with is an AST for describing
boolean expressions.  It's pretty simple code.  The only
thing kinda subtle is that the `eval` methods take in the
**set** of symbols that are True, rather than, say, a dictionary
that maps every possible symbol to either True or False. But
that kinda goes along with the naive solver (more on that later), where
you just iterate through the powerset of symbols and pass them into
`eval`.

Here is the AST code from `basic_bool.py`:

``` py
class Expression:
    def __and__(self, other):
        return AndPair(self, other)

    def __or__(self, other):
        return OrPair(self, other)

    def __invert__(self):
        return Negated(self)

    def symbols(self):
        return set()


class TrueVal(Expression):
    def __str__(self):
        return "T"

    def eval(self, _):
        return True


class FalseVal(Expression):
    def __str__(self):
        return "F"

    def eval(self, _):
        return False


class Negated(Expression):
    def __init__(self, x):
        self.x = x

    def __str__(self):
        return "~" + str(self.x)

    def symbols(self):
        return self.x.symbols()

    def eval(self, tvars):
        return not self.x.eval(tvars)


class Symbol(Expression):
    def __init__(self, name):
        self.name = name

    def __str__(self):
        return self.name

    def symbols(self):
        return {self.name}

    def eval(self, tvars):
        return self.name in tvars


class Pair(Expression):
    def __init__(self, x, y):
        self.x = x
        self.y = y

    def string_variables(self):
        return [f"({self.x})", f"({self.y})"]

    def symbols(self):
        return self.x.symbols() | self.y.symbols()

    def __str__(self):
        op = self.operator
        return op.join(self.string_variables())


class AndPair(Pair):
    operator = "&"

    def eval(self, tvars):
        return self.x.eval(tvars) and self.y.eval(tvars)


class OrPair(Pair):
    operator = "|"

    def eval(self, tvars):
        return self.x.eval(tvars) or self.y.eval(tvars)


TRUE = TrueVal()
FALSE = FalseVal()


def SYMBOL(name):
    return Symbol(name)
```

And then here's the solver code from `solver.py`:

``` py
def powerset(s):
    return chain.from_iterable(combinations(s, r) for r in range(len(s) + 1))


def braced(s):
    return "{" + s + "}"


def stringify_solutions(solutions):
    sorted_solutions = sorted(",".join(sorted(s)) for s in solutions)
    return "".join(braced(s) for s in sorted_solutions)


def solutions(expr, variables):
    """
    solutions(x | y, {"x", "y", "z"}) ==
    "{x}{x,y}{x,y,z}{x,z}{y}{y,z}",
    """
    return stringify_solutions(s for s in powerset(variables) if expr.eval(s))
```

I wrote some tests for the solver and did a little further
exploration, but that was the gist of my effort back then.

I found the AST code to be very satisfying in Python.

And it's easy to use:

``` py
T = TRUE
F = FALSE

x = SYMBOL("x")
y = SYMBOL("y")

@run_test
def strings():
    assert_str(T, "T")
    assert_str(F, "F")
    assert_str(T & F, "(T)&(F)")
    assert_str(T | x, "(T)|(x)")
    assert_str(~y | x, "(~y)|(x)")
```

There are deeper examples in the `test_*.py` examples in the repo.
