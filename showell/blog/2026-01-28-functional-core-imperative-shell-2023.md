## Functional Core, Imperative Shell (2023)

*January 28, 2026*

I've always been a big fan of Gary Bernhardt's work,
and I think one of his most popular screencasts during
his time working on "Destroy All Software" was about
the concept of
[Functional Core, Imperative Shell](https://www.destroyallsoftware.com/screencasts/catalog/functional-core-imperative-shell).

I did some quick coding back in 2023 that was along
the same lines of thinking.  I don't claim my code
here was completely faithful to Gary's teachings; I
am just noting that he expressed the underlying concepts
very well.

You can see [my repo here](https://github.com/showell/basic-mocking-in-python-and-js).

Consider the following Python code (calc.py):

``` py
import simple_plotter

def double(x):
    return x * 2

def triple(x):
    return x * 3

def calculate(x_vals, f):
    return [(x, f(x)) for x in x_vals]

def plot_function_with_plotter(x_vals, f, plotter):
    plotter(calculate(x_vals, f))

def plot(x_vals, f):
    plotter = simple_plotter.plot
    plot_function_with_plotter(x_vals, f, plotter)
```

The first three functions are clearly pure functions.  The
`plot_function_with_plotter` function has side effects, but
it's independent of the actual plotting implementation, since
we inject the `plotter` into the function.

And then finally the `plot` function not only has side effects
(of drawing some plot, of course), but it also has a hard-wired
dependency to `simple_plotter.plot`.

Before we figure out how to test the code, let's just see it
in action.

Here is `run.py`:

``` py
import calc

f = lambda x: calc.double(calc.triple(x))
x_values = [0, 1, 2, 3, 4, 5]

calc.plot(x_values, f)
```

It graphs the function `6*x` over the domain of
[0, 1, 2, 3, 4, 5].

Here is the output:

``` py
0
1 ******
2 ************
3 ******************
4 ************************
5 ******************************
```

As you can tell, the actual plotter is very primitive
Python code, but you could imagine using a much better
plotting library, and very little about `calc.py` would
need to change.

Here is `simple_plotter.py`:

``` py
def plot(tuples):
    for x, y in tuples:
        print(x, "*" * y)
```

The fun part is the test code in `test_calc.py`:

``` py
import calc

run_test = lambda f: f()

def with_mocked_value(obj, attr, val, f):
    old_val = getattr(obj, attr)
    setattr(obj, attr, val)
    f()
    setattr(obj, attr, old_val)

@run_test
def test_double():
    assert calc.double(1) == 2
    assert calc.double(2) == 4
    assert calc.double(3) == 6

@run_test
def test_triple():
    assert calc.triple(1) == 3
    assert calc.triple(2) == 6
    assert calc.triple(3) == 9

@run_test
def test_calculate():
    assert calc.calculate([1, 2, 3], calc.double) == [(1, 2), (2, 4), (3, 6)]
    assert calc.calculate([1, 2, 3], calc.triple) == [(1, 3), (2, 6), (3, 9)]

@run_test
def test_abstract_plotter():
    called = False
    def mock_plotter(tups):
        assert tups  == [(1, 6), (2, 12), (3, 18), (4, 24)]
        nonlocal called
        called = True

    f = lambda x: calc.double(calc.triple(x))
    calc.plot_function_with_plotter([1, 2, 3, 4], f, mock_plotter)
    assert(called)

@run_test
def test_actual_plot():
    called = False
    def mock_plotter(tups):
        assert tups  == [(1, 2), (2, 4)]
        nonlocal called
        called = True

    with_mocked_value(
        calc.simple_plotter,
        "plot",
        mock_plotter,
        lambda: calc.plot([1, 2], calc.double) ,
    )
    assert(called)
```

Note that there is no test runner here!  We use the native `assert` from
Python and a simple `run_test` decorator.

We also barely use `with_mocked_value` here.  It's just in the last
test. You could argue that the way the original code is written here
**prevents** the need for mocking, and that's kind of the point of
separating your functional core from an imperative shell.  I could
have actually structured `calc.py` to just be the functional core,
actually, but it kinda mixes in the imperative shell for the very
last function (i.e. `plot`).

This is a super lightweight mocking helper, by the way. It's not
versatile enough for every kind of testing, but it works fine
for simple stuff.

``` py
def with_mocked_value(obj, attr, val, f):
    old_val = getattr(obj, attr)
    setattr(obj, attr, val)
    f()
    setattr(obj, attr, old_val)
```

Another part of this exercise was that I ported everything over to
JS.  I won't show you all the JS code, but it's very similar in
spirit.

For example, here are the test helpers in JS:

``` js
function run_test(s, f) { f();}

function with_mocked_value(obj, attr, val, f) {
    old_val = obj[attr];
    obj[attr] = val;
    f();
    obj[attr] = old_val;
}
```

I have worked on some codebases where folks did a really bad
job of separating functional code from imperative code, or,
along the same lines, model code from UI code.  When you get
into that kind of codebase and have the mandate to keep 100%
line coverage on certain modules, you can get into some pretty
gruesome unit testing (lots of mocking, basically).

I generally prefer to focus my unit-testing efforts
on functional code. For the other pieces, the testing
strategies can be a lot more difficult to maintain.
