## Self-masking numbers (a math problem)

*January 28, 2026*

Certain decimal numbers have the property that
they are self-masking.  Consider the number 9901.

Note that 99 + 01 = 100.

Also note the following addition:

~~~
 990100
 + 9901
 ======
1000001
~~~

You can think of the smaller number "masking"
away the "01" piece of "990100" with the "99".

So the relationship there is 9901 * 101 = 1000001,
which you can easily verify with a calculator.

You can apply the masking trick multiple times:

~~~
>>> 9901 * 1010101010101
10001010101010001
>>> 9901 * 101010101010101
1000101010101010001
>>> 9901 * 10101010101010101
100010101010101010001
~~~

If you were asked to find the smallest multiple
of 9901 that has exactly 2 one digits and the
rest zeros, then the first example I gave tells
you to multiply 9901 by 101, giving you the
result of 1000001. It's not trivial to prove
that there's no smaller number that can possibly
work here, but that's a bit out of scope for
the basic trick here.

Let's say you have a bigger decimal number
like 99990001 that is also self-masking.

Start by multiplying it by a number that induces
the masking one time:

~~~
>>> 99990001 * 10001
1000000000001
~~~

Or twice:

~~~
>>> 99990001 * 100010001
10000000100000001
~~~

Note that a number with exactly three 1 digits
and otherwise 0 digits is, by definition, the
sum of three distinct powers of 10.

So you could formulate the question as "Find the
smallest number that is the sum of three distinct
powers of ten that is also divisible by 99990001?"

And the answer would be 10000000100000001.

So once you know these tricks with ordinary decimal
numbers, how do you disguise the problem?

Well, here goes: **What is the smallest number
that is both a multiple of 241 (decimal) and the
sum of three powers of 4?**

The main trick there is to convert 241 to base 4
and notice that it is 3301 in base 4. (Back to decimal,
you have: 241 = 3 * 64 + 3 * 16 + 0 + 1).

3301 is self-masking in base 4 for the same reason
that 9901 is self-masking in decimal! Or that
FF01 is self-masking in hex!

And then to mask it, this is all in base 4:

     3301 * 10101 = 100010001 (base 4 arithmetic)

And then the powers of 4 here are 1, `4**4` (256),
and `4**8` (65536), so going back to decimal, the
answer is: **65793**

A quick sanity check in the Python shell is helpful
maybe:

~~~
>>> 65793 / 241
273.0
~~~

There are certainly other ways to solve this problem,
but I enjoy the self-masking angle from a programming
perspective.  It's like an extension of bit shifting
and bit masking.
