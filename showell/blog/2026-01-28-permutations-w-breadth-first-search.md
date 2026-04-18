## Permutations w/breadth-first-search

*January 28, 2026*

It's always fun to try to reduce a problem to a
known algorithm.  For example, many problems in
math reduce themselves to some kind of graph
traversals.

I did a very small project in my
[permutations-with-breadth-first-search repo](https://github.com/showell/permutations-with-breadth-first-search)
to explore generating permutations with
a breadth first search.

The idea is that every permutation has some immediate
neighbors that are just off by one "transposition" of
two elements.  In my output below the elements of the
set that I am permuting are just the ints 1, 2, 3, and
4.

<pre>
all transpositions:
(12)
(13)
(14)
(23)
(24)
(34)

all permutations:
d=0 [1, 2, 3, 4]
d=1 [2, 1, 3, 4] == (12) on [1, 2, 3, 4]
d=1 [3, 2, 1, 4] == (13) on [1, 2, 3, 4]
d=1 [4, 2, 3, 1] == (14) on [1, 2, 3, 4]
d=1 [1, 3, 2, 4] == (23) on [1, 2, 3, 4]
d=1 [1, 4, 3, 2] == (24) on [1, 2, 3, 4]
d=1 [1, 2, 4, 3] == (34) on [1, 2, 3, 4]
d=2 [2, 3, 1, 4] == (13) on [2, 1, 3, 4] == (12) on [1, 2, 3, 4]
d=2 [2, 4, 3, 1] == (14) on [2, 1, 3, 4] == (12) on [1, 2, 3, 4]
d=2 [3, 1, 2, 4] == (23) on [2, 1, 3, 4] == (12) on [1, 2, 3, 4]
d=2 [4, 1, 3, 2] == (24) on [2, 1, 3, 4] == (12) on [1, 2, 3, 4]
d=2 [2, 1, 4, 3] == (34) on [2, 1, 3, 4] == (12) on [1, 2, 3, 4]
d=2 [3, 2, 4, 1] == (14) on [3, 2, 1, 4] == (13) on [1, 2, 3, 4]
d=2 [3, 4, 1, 2] == (24) on [3, 2, 1, 4] == (13) on [1, 2, 3, 4]
d=2 [4, 2, 1, 3] == (34) on [3, 2, 1, 4] == (13) on [1, 2, 3, 4]
d=2 [4, 3, 2, 1] == (23) on [4, 2, 3, 1] == (14) on [1, 2, 3, 4]
d=2 [1, 3, 4, 2] == (24) on [1, 3, 2, 4] == (23) on [1, 2, 3, 4]
d=2 [1, 4, 2, 3] == (34) on [1, 3, 2, 4] == (23) on [1, 2, 3, 4]
d=3 [2, 3, 4, 1] == (14) on [2, 3, 1, 4] == (13) on [2, 1, 3, 4] == (12) on [1, 2, 3, 4]
d=3 [4, 3, 1, 2] == (24) on [2, 3, 1, 4] == (13) on [2, 1, 3, 4] == (12) on [1, 2, 3, 4]
d=3 [2, 4, 1, 3] == (34) on [2, 3, 1, 4] == (13) on [2, 1, 3, 4] == (12) on [1, 2, 3, 4]
d=3 [3, 4, 2, 1] == (23) on [2, 4, 3, 1] == (14) on [2, 1, 3, 4] == (12) on [1, 2, 3, 4]
d=3 [3, 1, 4, 2] == (24) on [3, 1, 2, 4] == (23) on [2, 1, 3, 4] == (12) on [1, 2, 3, 4]
d=3 [4, 1, 2, 3] == (34) on [3, 1, 2, 4] == (23) on [2, 1, 3, 4] == (12) on [1, 2, 3, 4]

distance counts
0 1
1 6
2 11
3 6
</pre>

The code to generate this output is far from beautiful,
but I think it's nice that it all works on one of the
most well-known algorithms in computer science, and, for
that matter, job interview questions.  And it's one of
those things that I can re-invent from scratch if you
stuck a gun to my head, but it's nice to have the code
around.

Here is `breadth_first_permutations.py` in all its
hack-ish glory:

``` py
print("<pre>")


def breadth_first_search(top, *, neighbors):
    q = [top]
    depth_dict = dict()
    depth_dict[top] = 0
    depth = 0
    while q:
        depth += 1
        new_q = []
        for obj in q:
            for neighbor in neighbors(obj):
                if neighbor not in depth_dict:
                    depth_dict[neighbor] = depth
                    new_q.append(neighbor)
        q = new_q
    return depth_dict


LIST_SIZE = 4


class Transposition:
    def __init__(self, i, j):
        assert i >= 1
        assert i < j
        assert j <= LIST_SIZE
        self.i = i
        self.j = j

    def __str__(self):
        return f"({self.i}{self.j})"


def make_transpositions():
    transpositions = []
    for i in range(LIST_SIZE):
        for j in range(i + 1, LIST_SIZE):
            t = Transposition(i + 1, j + 1)
            transpositions.append(t)
    return transpositions


transpositions = make_transpositions()
print("all transpositions:")
for t in transpositions:
    print(t)

print()


class Permutation:
    def __init__(self, lst, *, parent, transposition):
        if parent is None:
            assert transposition is None
        assert set(lst) == set(range(1, LIST_SIZE + 1))
        self.lst = lst
        self.parent = parent
        self.transposition = transposition

    def neighbor(self, t):
        lst = self.lst[:]
        i = lst.index(t.j)
        j = lst.index(t.i)
        (lst[i], lst[j]) = (lst[j], lst[i])
        return Permutation(lst, parent=self, transposition=t)

    def neighbors(self):
        return [self.neighbor(t) for t in transpositions]

    def __eq__(self, other):
        return self.lst == other.lst

    def __str__(self):
        s = str(self.lst)
        if self.parent is None:
            return s
        return f"{s} == {self.transposition} on {self.parent}"

    def __hash__(self):
        return hash(tuple(self.lst))


orig = Permutation(list(range(1, LIST_SIZE + 1)), parent=None, transposition=None)
distance = breadth_first_search(orig, neighbors=lambda perm: perm.neighbors())

print("all permutations:")
for p, d in distance.items():
    print(f"d={d}", p)
print()

print("distance counts")
for i in range(LIST_SIZE):
    print(i, len([d for d in distance.values() if d == i]))

print("</pre>")
```

When I'm just experimenting with concepts, I **definitely** use Python
as a scripting language in the most ugly sense.  But it works!
