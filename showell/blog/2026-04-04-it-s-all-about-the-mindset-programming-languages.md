## It's all about the mindset (programming languages)

*April 4, 2026*

When you start learning a new programming language, you usually
just need to put yourself into the mindset of the people who
created the language.  It's often a single male person who
created the language (or at least is the primary driver):

    * Elm: Evan Czaplicki
    * Roc: Richard Feldman
    * Zig: Andrew Kelley
    * Odin: Ginger Bill
    * Go: Robert Pike (but more of a committee effort?)

All these folks know that their languages have important
tradeoffs, and some of them are negative.

### Folders for packages get annoying (Go / Odin)

The packaging systems for Go and Odin (the former inspired
the latter) are annoying, because you tend to have lots of
folders with just one or two source files.  For example,
you might have database/database.go and html/html.go.

For my ~1000-line Go project, I have 6 folders in my project!
It's partly my fault that I like to decompose things into
small units (I have 12 go files), but 6 folders is the ridiculous
consequence.

But you know what. It's just a folder. So I get over it.

Thinking that folders are somehow expensive or annoying is just
a mindset problem.

### Immutability can be inconvenient (Elm / Roc)

I didn't get too far with Roc, but I did a lot of Elm.  Immutability
is definitely inconvenient at times, but it provides so many benefits.
It takes me about three or four days of programming in Elm before I
get into the groove.  But you almost get to that if-it-compiles-it-works
nirvana.

### Memory management needs to be 100% reliable (Zig / Odin)

The so-called dangerous languages (C, Odin, Zig) are only dangerous
if you don't learn the basics of memory management.  And you have to
get your programs 100% correct. (That' technically true in languages
with automatic memory management, too, in the broader sense, but you
know what I mean.)

So just learn how to do it.  And get things 100% correct.

It's important that Zig and Odin have pretty decent testing paradigms,
and the test runners immediately report memory leaks or buffer overflows.

The "defer" keyword is a godsend, and the language designers are smart
enough to have deferred deallocations happen in reverse.  Even though
a deferred statement is non-local at runtime, it's way more important
that it's local from the perspective of the person reading the code.

I love how Zig treats allocators as a first-class concept, at least on
a cultural level.

It's important to understand the lifetime of your data in any
programming language, and then once you understand the natural lifetimes
of data, the decisions about who "owns" the data are generally quite
straightforward.

Arena allocators are useful when you have natural cycles in your
application. For example, if you are writing a first-person shooter
game, then there's a very natural cycle of drawing all the stuff
for the next frame. For anything that's transient but still needs to
go on the heap (for whatever reason), just use an arena allocator.
