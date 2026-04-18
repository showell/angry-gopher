# The Customer Is Always Writing

*Written 2026-04-18. A humor piece by request. The voice is a
fictional human developer venting to a fictional colleague
about a fictional customer whose mannerisms bear, by sheer
coincidence, certain resemblances to actual Steve Howell. The
caricature is offered in good faith.*

**← Prev:** [The Bar for Done](the_bar_for_done.md)

---

Look, Marcus. Sit down. Pour yourself something. I have to
tell you about this client.

So first of all: I have never, in my entire career, had a
client who demands essays before code. Never. You know what
most clients want? They want the code. They want it shipped.
They want it merged. The most they want before code is a
quick design doc, maybe a slack thread, like "here's what I'm
gonna do, sound good? cool, ship it." This client? Wants. An.
Essay.

And not just one essay. One essay would be fine. I could
write a one-essay client. This guy wants an essay BEFORE the
plan, an essay TO MAKE the plan, an essay ABOUT the plan, an
essay AFTER the plan to remind us what the plan was, and
then — Marcus, listen — then an essay reflecting on what we
LEARNED from following the plan. Five essays. For one
feature. With code snippets in some, but not all, because
*some essays are about the code we are going to write* and
*some essays are about whether we are allowed to write it.*

And he wants them chained. Prev/Next links at the top of
each essay. Like an old-school blog. He noticed when one was
missing a forward link last week and stopped what he was
doing to make me add it. Stopped. The work. To fix. A back
link.

But that's not the worst part. The worst part is the UI.

So the existing UI, right? The existing UI he admits is bad.
He told me it was bad. *In writing.* In an essay he made me
write — about how to NOT change the UI — he wrote, and I'm
quoting from my own commit, "the current behavior is not the
optimal UI; he concedes that openly." HE WROTE THAT. About
his own product. And then, in the very next sentence, he
told me to port it verbatim. The bad version. Faithfully.
Down to the one-pixel click threshold that turns half the
clicks into accidental drags.

He KNOWS. He KNOWS it's bad. He's PROUD of knowing. He still
wants it ported as-is.

So I asked, like a normal human being would ask, "should we
maybe at least bump the threshold up to like four pixels so
clicks aren't a coin flip?" And he said no. NO. He said —
you're gonna love this — "anything that changes the
perceived behavior relative to TS is out of scope for
reaching done, even if it's an obvious improvement."

Marcus. EVEN IF IT'S AN OBVIOUS IMPROVEMENT. He wrote a
clause excluding improvements. From a port. Of his own
software.

Apparently this is a feature. Apparently if I improve the
crappy UI during the port, then we can't tell whether a
reported bug is a port defect or a deliberate change, and
that means "done" becomes — and again, his word, not mine —
"unfalsifiable." UNFALSIFIABLE. About a card game. He used
the word UNFALSIFIABLE about a card game.

And I know what you're going to say. You're going to say
"well, at least the existing UI must be working for
someone." And it IS! It works for him! And it works for —
brace yourself — his mother. Susan. Susan plays this card
game. On a tablet. And the formal success criteria for the
port — actual written-down success criteria, in an essay he
made me write — is that Steve and his mother Susan, playing
side by side, should not be able to tell which version
they're using.

His mother, Marcus. He has invoked his mother as the QA
criterion. I have to make sure Susan enjoys it the same
amount as before.

OK and now I'm going to tell you about the LEFT and the
RIGHT. So at one point I'm wiring up some side-aware logic
— "this card goes on the left of the stack, that one goes
on the right" — and I do what any sane developer does, which
is I parametrize over the Side type and write one function
that handles both cases. Symmetric. Clean. DRY. Beautiful.
He sees the diff and types — and I have this saved — he
types "strong concept of LEFT and RIGHT. Don't try to
generalize them too much. Treat them as two separate similar
things."

TWO SEPARATE SIMILAR THINGS. He wants me to write the same
function twice. Once for Left, once for Right. With slightly
different names. Because they are, quote, "two distinct
cases, handled directly where they're used."

And listen, the maddening thing — the truly infuriating
part — is that he was right. There was a real bug hiding in
my clean parametrized version. Side-specific. Wouldn't have
surfaced for weeks. I had to type the words "Steve was
right" into a commit message. *To you.* Sitting across from
me. Listening to me complain.

I haven't even told you about the memory files. He has a
memory system. It's separate from the code. It's separate
from the essays. It's a *third thing*. Every time he gives
me substantive feedback I'm supposed to extract it into a
durable memory file. With frontmatter. With a name field, a
description field, a type field — there are *four* types,
"user" or "feedback" or "project" or "reference" — and a
body that's structured "rule, then **Why:**, then **How to
apply:**."

There are eighty-seven of these files. I've counted. They're
all in a directory that gets loaded into context on every
conversation start. If I add one and forget to update the
index, a hook yells at me.

A hook, Marcus. A hook yells at me.

And — OK, last one and then I'll stop — last week he
decided we were going to rip a batch of old essays. Throw
them away. Just delete them, right? Right? *No.* Of course
not. We had to write an essay about ripping the essays.
*Then* we had to write an essay carrying forward the
insights of the ripped essays so the insights survived. Then
we had to identify the three "durable" ones and PARK them in
their respective repos under a filename — I am not making
this up — called "DEEP\_READ.md." Then push them. To three
separate GitHub repos. With provenance comments. Then commit
the rip. Then push the rip.

And then, and *then*, before signing off, he made me write
an essay called "For the Next Session" — addressed to
future-me. A handoff letter. From present-me. To future-me.
In case my laptop crashed. So that future-me, logging in the
next morning, would have a recovery note explaining where
the load-bearing commits were and what was safe to touch.

I read it back, Marcus. It's actually pretty good. It has
specific anchors. It tells future-me which commits matter.
It has a section called "the 10% — things I'd want to know
cold." It's thoughtful. It's well-organized.

And I'm going to keep doing all of this. I'm going to keep
writing the essays. I'm going to keep porting the bad UI
verbatim. I'm going to keep two separate functions for Left
and Right. I'm going to keep updating MEMORY.md every time I
add a file. I'm going to keep chaining Prev and Next links.
I'm going to keep writing recovery notes to my future self.
I'm going to keep prefixing the milestone commits with the
literal word MILESTONE in all caps.

Because here's the thing — and Marcus, don't tell him I
said this —

the project is going really, really well.

— Me
