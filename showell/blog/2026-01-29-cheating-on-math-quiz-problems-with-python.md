## Cheating on math quiz problems (with Python)

*January 29, 2026*

In yesterday's blog I posed the following question,
and I showed how you could solve the problem using
pretty minimal calculation (*I only used the computer
for convenience, but there are pretty quick manual
ways to convert numbers back and forth between
base 4 and base 10 if you have pen and paper and
are reasonably adept at arithmetic.*)

**What is the smallest number
that is both a multiple of 241 (decimal) and the
sum of three powers of 4?**

I posed a very similar question to my programming
buddy Apoorva, but I forgot to tell him that
Python wasn't allowed! I asked him this:

**What is the smallest number
that is both a multiple of 16773121 (decimal) and the
sum of three powers of 4?**

And he came back pretty quickly with the
answer: 281474993487873

And when he showed me the answer, it was a
screenshot from a computer program!

He technically wasn't cheating, because I didn't
explain the rules, but, yeah, he was cheating.

So now I'm gonna cheat too!

Here's a program that correctly produces the
answer rather efficiently:

``` py
def enumerate_power_of_4_triplets(until_callback):
    i = 0
    j = 1
    k = 2

    # We compute higher powers of 4 lazily, and k will
    # always be the last index index into the list
    # (i.e. K + 1 == len(powers))
    powers = [1, 4, 16]

    while k < 100:
        assert k + 1 == len(powers)

        triplet_sum = powers[i] + powers[j] + powers[k]

        # for debugging
        # print(i, j, k, triplet_sum)

        if until_callback(triplet_sum):
            return triplet_sum

        # Our invariant is that i < j < k,
        # and we try to always bump the smallest
        # number we can.
        if i + 1 < j:
            i += 1
        elif j + 1 < k:
            j += 1
            i = 0
        else:
            powers.append(4 * powers[k])
            k += 1
            i = 0
            j = 1

answer = enumerate_power_of_4_triplets(
    until_callback=lambda n: n % 16773121 == 0
)
print(answer)
```

Here is my next question:

**Are there are any numbers for which none of
its infinite multiples can be expressed as a
sum of three distinct powers of 4? If so, what's the
smallest integer with that property?**

There may be some interesting number theory to
answer that question, but my intention is to
brute-force it with Python! (not till infinity,
of course, but up to some pretty big numbers)

Just to be clear, I have no idea what the answer
to my question is yet.

But as soon as I run my program, I think I have
some candidates:

~~~
5 does not seem to divide any triplets
17 does not seem to divide any triplets
31 does not seem to divide any triplets
41 does not seem to divide any triplets
~~~

Here is the loop that I used:

``` py
def seek_bad_numbers():
    bad_numbers = set()

    for i in range(2, 50):
        # Skip redundant answers. If 5 doesn't work, neither will
        # 10, 15, 20, etc.
        if any(i % bad_number == 0 for bad_number in bad_numbers):
            continue
        answer = enumerate_power_of_4_triplets(
            until_callback=lambda n: n % i == 0
        )
        if answer is None:
            bad_numbers.add(i)
            print(f"{i} does not seem to divide any triplets")
```

I didn't **prove** that 5 is an "impossible divisor", since
I capped my searches at a finite maximum power of 4. I used
`k < 200` as my upper bound. But I would be kinda surprised
if the smallest triplet that divided 5 included some massive
power of 4.

It's noteworthy that 5 and 17 are both trivially divisors
of **pairs** of powers-of-four.

~~~
5 == 1 + 4
17 == 1 + 16
~~~

I would have to search harder to find out if any multiple
of 31 can be expressed as the sum of a pair of powers.
