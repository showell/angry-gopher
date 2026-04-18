## Polynomials of polynomials of polynomials (2023)

*January 28, 2026*

Back in 2023 I became fascinated with Abstract Algebra, and I
used Python to explore some concepts.

You can see my [abstract-algebra repo here](https://github.com/showell/abstract-algebra)

I will start with the end result, where I wanted to generate
a very large poly-over-poly-over-poly.

Just read the comments to see the absurdity of the exercise.

See `test_poly_poly_poly.py`:

``` py
from commutative_ring import verify_ring_properties
from lib.test_helpers import assert_equal, assert_str, run_test
from poly_integer import IntegerPoly
from math_helper import MathHelper
from poly import SingleVarPoly
from poly_poly import PolyPoly
from poly_poly_poly import PolyPolyPoly

IP = IntegerPoly.from_list
PP = PolyPoly.from_list
PPP = PolyPolyPoly.from_list

# Slowly build a really big polynomial of polynomial of polynomial monstrosity.

# Start simple with simple integer polynomials over x.
ip_a = IP([1, 2]) # 2x + 1
ip_b = IP([3, 4]) # 4x + 3
ip_c = ip_a * ip_b # 8x**2 + 10x + 3

assert_str(ip_a, "(2)*x+1")
assert_str(ip_b, "(4)*x+3")
assert_str(ip_c, "(8)*x**2+(10)*x+3")

# Now make polynomials of polynomials.
# Note that we are making a polynomial in p, but each term is a polynomial in x.
pp_a = PP([ip_a, ip_c])
assert_str(pp_a, "((8)*x**2+(10)*x+3)*p+(2)*x+1")

pp_b = PP([ip_b, ip_a])
assert_str(pp_b, "((2)*x+1)*p+(4)*x+3")

pp_c = pp_a * pp_b
assert_str(
    pp_c,
    "((16)*x**3+(28)*x**2+(16)*x+3)*p**2+((32)*x**3+(68)*x**2+(46)*x+10)*p+(8)*x**2+(10)*x+3",
)

# Now we make polynomials of polynomials of polynomials!
ppp_a = PPP([pp_a, pp_c])
assert_equal(ppp_a.type_string, "SingleVarPoly.SingleVarPoly.SingleVarPoly.int")

# This is a polynomial over q, where the terms are polynomials of p over polynomials of x.
assert_str(
    ppp_a,
    "(((16)*x**3+(28)*x**2+(16)*x+3)*p**2+((32)*x**3+(68)*x**2+(46)*x+10)*p+(8)*x**2+(10)*x+3)*q+((8)*x**2+(10)*x+3)*p+(2)*x+1",
)

# Now start evaluating. In ppp_a, we are going to substitute the value of pp_c for q.
pp_d = ppp_a.eval(pp_c)
assert_str(
    pp_d,
    "((256)*x**6+(896)*x**5+(1296)*x**4+(992)*x**3+(424)*x**2+(96)*x+9)*p**4+((1024)*x**6+(3968)*x**5+(6304)*x**4+(5264)*x**3+(2440)*x**2+(596)*x+60)*p**3+((1024)*x**6+(4608)*x**5+(8336)*x**4+(7808)*x**3+(4012)*x**2+(1076)*x+118)*p**2+((512)*x**5+(1728)*x**4+(2288)*x**3+(1496)*x**2+(486)*x+63)*p+(64)*x**4+(160)*x**3+(148)*x**2+(62)*x+10",
)

# Next we substitute the value of ip_a for p.
ip_d = pp_d.eval(ip_a)
assert_str(
    ip_d,
    "(4096)*x**10+(30720)*x**9+(103680)*x**8+(207616)*x**7+(273472)*x**6+(247808)*x**5+(156544)*x**4+(68112)*x**3+(19548)*x**2+(3346)*x+260",
)

# And finally we substitute 1000000000 for x.  And we are back to integers!
big_int = ip_d.eval(1000000000)
assert (
    big_int
    == 4096000030720000103680000207616000273472000247808000156544000068112000019548000003346000000260
)


# And the whole system forms a ring!

@run_test
def verify_ring_axioms():
    samples = [
        PPP([pp_a, pp_d, pp_c]),
        PPP([pp_c, pp_a]),
        PPP([pp_a, pp_d]),
        PPP([pp_b]),
    ]

    math = MathHelper(
        value_type=SingleVarPoly,
        zero=PolyPolyPoly.zero,
        one=PolyPolyPoly.one,
    )

    verify_ring_properties(math, samples)
```

Next see `poly_poly_poly.py`:

``` py
from poly import SingleVarPoly
from poly_poly import PolyPoly
from math_poly_poly import PolyPolyMath


class PolyPolyPoly:
    const = lambda c: SingleVarPoly.constant(PolyPolyMath, c)
    zero = const(PolyPoly.zero)
    one = const(PolyPoly.one)
    q = SingleVarPoly.degree_one_var(PolyPolyMath, "q")

    @staticmethod
    def from_list(lst):
        return SingleVarPoly(PolyPolyMath, lst, "q")
```

The above code is surprisingly small, because it basically
works off of `SingleVarPoly`, which just takes a generic type,
roughly speaking.

We'll get to `SingleVarPoly` in a sec, but notice how PolyPoly
looks almost exactly the same structurally:

``` py
from poly import SingleVarPoly
from poly_integer import IntegerPoly
from math_poly_integer import IntegerPolyMath


class PolyPoly:
    const = lambda c: SingleVarPoly.constant(IntegerPolyMath, c)
    zero = const(IntegerPoly.zero)
    one = const(IntegerPoly.one)
    p = SingleVarPoly.degree_one_var(IntegerPolyMath, "p")

    @staticmethod
    def from_list(lst):
        return SingleVarPoly(IntegerPolyMath, lst, "p")
```

The `SingleVarPoly` class does a lot more heavy lifting.
Notice it also uses lots of `__dunder__` methods for add,
mul, neg, pow, etc.


``` py
class SingleVarPoly:
    def __init__(self, math, lst, var_name):
        enforce_math_type(math)
        enforce_list_types(lst, math.value_type)
        if len(lst) > 1 and var_name is not None:
            enforce_type(var_name, str)
        self.lst = lst
        self.math = math
        self.var_name = var_name
        assert hasattr(math, "type_string")
        enforce_type(math.type_string, str)
        self.type_string = f"SingleVarPoly.{math.type_string}"
        self.simplify()

    def __add__(self, other):
        self.enforce_partner_type(other)
        return self.add_with(other)

    def __eq__(self, other):
        self.enforce_partner_type(other)
        return self.lst == other.lst

    def __mul__(self, other):
        self.enforce_partner_type(other)
        return self.multiply_with(other)

    def __neg__(self):
        return self.additive_inverse()

    def __pow__(self, exponent):
        return self.raised_to_exponent(exponent)

    def __str__(self):
        return self.polynomial_string()

    def additive_inverse(self):
        lst = self.lst
        additive_inverse = self.math.additive_inverse
        return self.new([additive_inverse(elem) for elem in lst])

    def add_with(self, other):
        if other.is_zero():
            return self

        zero = self.math.zero
        lst1 = self.lst
        lst2 = other.lst
        add = self.math.add

        lst = polynomial_algorithms.add(lst1, lst2, add=add, zero=zero)

        var_name = self.var_name or other.var_name
        return SingleVarPoly(self.math, lst, var_name)

    def enforce_partner_type(self, other):
        assert type(other) == SingleVarPoly
        assert type(other.math) == type(self.math)
        assert type(self) == type(other)
        if self.var_name is not None and other.var_name is not None:
            assert self.var_name == other.var_name

    def eval(self, x):
        add = self.math.add
        mul = self.math.multiply
        power = self.math.power
        zero = self.math.zero
        lst = self.lst
        return polynomial_algorithms.eval(
            lst, x=x, zero=zero, add=add, mul=mul, power=power
        )

    def is_one(self):
        return len(self.lst) == 1 and self.lst[0] == self.math.one

    def is_zero(self):
        return len(self.lst) == 0

    def multiply_with(self, other):
        if other.is_zero():
            return other

        if other.is_one():
            return self

        zero = self.math.zero
        add = self.math.add
        mul = self.math.multiply
        lst1 = self.lst
        lst2 = other.lst

        lst = polynomial_algorithms.multiply(lst1, lst2, add=add, mul=mul, zero=zero)
        var_name = self.var_name or other.var_name
        return SingleVarPoly(self.math, lst, var_name)

    def new(self, lst):
        return SingleVarPoly(self.math, lst, self.var_name)

    def one(self):
        return self.new([self.math.one])

    def polynomial_string(self):
        var_name = self.var_name
        zero = self.math.zero
        one = self.math.one
        lst = self.lst
        return polynomial_algorithms.stringify(
            lst, var_name=var_name, zero=zero, one=one
        )

    def raised_to_exponent(self, exponent):
        enforce_type(exponent, int)
        if exponent < 0:
            raise ValueError("we do not support negative exponents")

        if exponent == 0:
            return self.one()
        if exponent == 1:
            return self
        return self * self.raised_to_exponent(exponent - 1)

    def simplify(self):
        lst = self.lst
        zero = self.math.zero
        while lst and lst[-1] == zero:
            lst = lst[:-1]
        self.lst = lst

    @staticmethod
    def constant(math, c):
        enforce_type(c, math.value_type)
        return SingleVarPoly(math, [c], None)

    @staticmethod
    def degree_one_var(math, var_name):
        enforce_type(var_name, str)
        return SingleVarPoly(math, [math.zero, math.one], var_name)
```

What did I conclude from this exercise?
* rings are interesting
* Python is pretty good at expressing math concepts

For whatever reason, I have never worked in a job where I got to
do scientific computing or math-related software.  I got sucked
into the world of building web apps. I'd like to change that
some day!

I have dabbled with things like Jupyter notebooks in Python.
Maybe it's time for a deeper dive.
