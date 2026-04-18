## Mentoring Apoorva

*February 20, 2026*

I have been mentoring a college student named
Apoorva Pendse (see [his GitHub repo](https://github.com/apoorvapendse))
since December 2025.  We got
connected somewhat indirectly through Zulip's
participation in the Google Summer of Code.

I'm a long-time contributor to the Zulip Open
Source project and a former employee of its
related company, Kandra Labs.  I met Apoorva
in early 2025 and mostly just interacted with
him on a social level, although back then I
did advise him on some small projects.

After a successful "Summer of Code", Apoorva
has continued to work on Zulip code despite
being back in "university life".

I had been mostly away from Zulip during
2025, but when I came back to catch up on news,
I started talking to Apoorva again, and we
got talking about some of the projects he was
working on.  Since some of them were in areas
of the code that I was familiar with, I started
unofficially mentoring him on a daily basis.

Fast forward to now.  We have been working quite
closely on a daily basis, including weekends, for
almost exactly two months now.

Apoorva lives in India, and I live in the US, so
all of our interaction is remote (and time shifted
by 10.5 hours!).  We naturally use the Zulip
tool itself as our primary means of collaboration
on improving Zulip.

We mostly talk on the "macandcheese" Zulip
instance that I administer.  This instance is
free to me through the generosity of the project,
and it is completely hosted on Zulip Cloud.

If you have read this far, I encourage you to join
[macandcheese](https://macandcheese.zulipchat.com/register).
As an aside, the whimsical name was actually coined
by another former GSoC student.

### Zulip collaboration style

When I work on Zulip projects (and projects in
general), I am fairly fanatical about creating
new dedicated **channels** on Zulip for even
seemingly small projects.  I have successfully
indoctrinated Apoorva into this philosophy, and
I think he would agree that it truly leverages
the power of Zulip. We not only have topics within
channels, but we segregate our conversations
according to which project we are working on
at the time. (There are always multiple projects
active; it's the nature of the beast.)

Just to illustrate how specific we can get in
our channels (emphasis on channels: not topics,
channels!), here are some recent examples:

* webex
* message store cleanup
* emoji picker
* gif picker project

In a typical work week, Apoorva and I exchange
roughly 1000 messages, so the discipline of
talking about project-specific topics within
project-specific channels pays huge dividends
over time.

### Apoorva has been productive!

Apoorva has been very productive during the two
months of our collaboration, and I will take
partial credit for his achievements.

Here are the commits that Tim (the project leader)
has **already merged to Zulip main** during our two months:

~~~
 2025-12-15 : tenor: Focus edit textarea on closing tenor picker with esc.
 2025-12-16 : eslint: Disable `import/unambiguous` rule for .md files.
 2025-12-19 : message_select: Fix text selection not working for clicks.
 2025-12-19 : tenor_picker: Use the filter-input styling for search input.
 2025-12-21 : search: Avoid showing topic suggestions from negated channels.
 2025-12-22 : search_suggestions: Show combined `#channel>topic` pills.
 2025-12-24 : message_header: Don't shift vdots on hiding icons.
 2025-12-25 : abstract_network_gif: Introduce an abstract base class.
 2025-12-25 : gifs: Introduce `abstract_gif_network.ts`.
 2025-12-25 : gifs: Unify GIPHY and Tenor UI.
 2025-12-25 : tenor: Introduce callback mechanism to render GIFs.
 2025-12-25 : tenor: Introduce the `TenorNetwork` class.
 2025-12-25 : tenor: Make `tenor.ts` members provider agnostic.
 2025-12-25 : tenor: Move `raw_tenor_result` parsing logic from `render_gifs_to_grid`.
 2025-12-25 : tenor: Move network stuff over to `tenor_network.ts`.
 2025-12-25 : tenor: Move the request payload construction from UI.
 2025-12-25 : tenor: Rename `.tenor-gif` and the tenor_gif template.
 2025-12-25 : tenor: Use `ask_tenor_for_gifs` to isolate network calls.
 2025-12-25 : tenor_network: Use a new network object per picker instance.
 2025-12-26 : gifs: Generate network objects based on realm state.
 2025-12-27 : gifs: Simplify `gif_picker_ui.hbs`.
 2025-12-31 : node_tests: Remove unused giphy.ts esm mock.
 2026-01-01 : user_presence: Remove dead `.user-name-and-status-wrapper`.
 2026-01-02 : buddy_list: Introduce background_task for non awaited code.
 2026-01-04 : activity_tests: Remove mock_template for presence rows.
 2026-01-06 : gifs: Introduce fallback placement options for GIFs.
 2026-01-07 : gifs: Rename `giphy_rating` to `gif_rating_policy`.
 2026-01-08 : quote_message: Improve sad-path UX when fetching raw_content.
 2026-01-09 : web: Use `apply_markdown` to get raw markdown.
 2026-01-12 : click: Prevent composebox refocus on double/triple clicks.
 2026-01-13 : gif_state: Use a better name for rating policy update handler.
 2026-01-13 : gifs: Rename `gif_rating_options` to `gif_rating_policy_options`.
 2026-01-14 : message_header: Avoid hiding icons on smaller widths.
 2026-01-14 : tenor_picker: Use `keyup` only when trying to focus GIFs.
 2026-01-15 : emoji_frequency: Ignore uncached messages on deletion events.
 2026-01-16 : emoji_frequency: Ignore reaction events from muted sources.
 2026-01-21 : emoji_frequency: Move data handling to emoji_frequency_data.ts
 2026-01-21 : emoji_frequency_data: Use better names for add/remove handlers.
 2026-01-22 : gifs: Focus compose box on closing picker with Escape.
 2026-01-22 : gifs: Prevent message navigation when navigating with arrows.
 2026-01-22 : gifs: Prevent stale network calls beacuse of debouncing.
 2026-01-27 : gif_picker: Switch to a two-column layout.
 2026-01-31 : click: Revert getSelection() check to determine link selection.
 2026-02-04 : docs: Add Spectacle for screenshot software on Linux.
 2026-02-07 : setup_docs: Use the `usermod` command for docker.
 2026-02-09 : message_quoting: Improve comment about using raw_content.
 2026-02-09 : quote_messages: Cache raw_content after fetching it.
 2026-02-10 : copy_messages: Improve end_id detection in analyze_selection.
 2026-02-10 : quote_message: Attempt to use `raw_content` in error callback.
 2026-02-11 : message_store: Conditionally update message's raw_content.
 2026-02-17 : search_pill: Dedupe types that can use PillRenderData.
 2026-02-17 : search_pill: Use hbs to render combined channel topic.
~~~

That's over 50 commits, and I would say that I have
participated in about 70% of those, and I even have
co-author status on some of them.

If you want to contribute to the Zulip project as a
developer, there is a high expectation of being a
generalist, and you can glean from the above commits
that Apoorva has worked in several areas of the codebase
recently.  Having said that, there have been some major
areas of concentration, so I will speak to a few of those.

### Tenor/Giphy unification

During our first few weeks, Apoorva had been tasked
with unifying code for two of Zulip's gif pickers
(Tenor and Giphy).  Zulip had long been using Giphy,
but it only started using Tenor during the summer of
2025.

During the initial prototyping of the Tenor project,
it was expedient to basically copy/paste a lot of
the Giphy code to reduce the risk of breaking Giphy
features while still working out bugs with the
Tenor prototype.

Once the Tenor prototype stabilized (as well as Tenor
itself being validated as a gif vendor),
it was clearly time to de-duplicate the new
code and move to more general-use components.

It was also time to clean up any technical debt
that had been accrued even before the Tenor project.

I think one of my assets as a senior developer
(I've been doing this for 40 years) is that I deeply
understand the best way to organize code for
re-use.

In some ways it's not actually rocket science.
Most of the tried-and-true principles of object
oriented development apply to the Zulip codebase,
and of course it helps to work with modern
JavaScript (er, actually TypeScript) in order
to facilitate good design.  (I believe some of
the giphy code was written before Zulip even
had the luxury of using es6 classes.)

Also, Apoorva already knew most of those principles
himself, so in many senses I was just validating
what he already knew, or, perhaps in some cases,
simply emphasizing the importance of them.

But there's also the logistics of incrementally
moving toward the final version, and that's an
area where my decade of working on the project
was probably most helpful.

We have pretty detailed conversations about
how to structure PRs to get from point A to
point B in the lease disruptive way possible.

#### Outcome

Zulip now has these generic files for picking
gifs:

```
 wc -l gif_picker_*
   23 gif_picker_popover_content.ts
  289 gif_picker_ui.ts
  312 total
```

And then there is a small amount of code that
is specific to each network:

```
 wc -l *network.ts
  39 abstract_gif_network.ts
 138 giphy_network.ts
 139 tenor_network.ts
 316 total
```

Here is `abstract_gif_network.ts` in its entirety:

``` ts
export type GifInfoUrl = {
    preview_url: string;
    insert_url: string;
};

export type RenderGifsCallback = (urls: GifInfoUrl[], next_page: boolean) => void;

export type GifProvider = "tenor" | "giphy";
// When a user clicks on the gif icon either while composing a
// message in the normal compose box or while editing a
// message, the UI will need to talk to a third party
// vendor such as tenor to get gifs.

// The network class will need to support this protocol.

// Typically, the UI will instantiate an object from a derived subclass
// of `GifNetwork`.
// Then they will make one or more calls to ask_for_*() to ask the
// third party to send back gif urls. See the callback
// type definition as well (RenderGifsCallback).

// The final piece of the contract is that if the user abandons the UI
// (typically the picker is a popover, but we don't care here), then
// the UI should call `abandon()` below. And then they should
// obviously never call the object again.
export abstract class GifNetwork {
    abstract get_provider(): GifProvider;
    abstract is_loading_more_gifs(): boolean;
    abstract ask_for_default_gifs(
        next_page: boolean,
        render_gifs_callback: RenderGifsCallback,
    ): void;
    abstract ask_for_search_gifs(
        search_term: string,
        next_page: boolean,
        render_gifs_callback: RenderGifsCallback,
    ): void;
    abstract abandon(): void;
}
```

### Organizing emoji frequency code

Another project that Apoorva took on was related
to Zulip's emoji picker for reactions.  When you
react to a Zulip message with an emoji (e.g.
thumbs-up!), you can open the emoji picker to find
pertinent emojis.

There are certain emojis that are used very
frequently on Zulip (and in general), such as
the emojis for "thank you", "thumbs up", "smile",
and a couple other celebration-related emojis.

Up until 2025 Zulip just had a hard coded list
of emojis that were anecdotally popular among
users, and those actually worked quite well, in
my opinion. The product team decided to refine the
feature by actually calculating the frequency
of previous emoji usage on a per-user basis.

They tasked another programmer to come up with a
prototype solution. The good outcome of that project
was that even a fairly naive algorithm for determining
the frequency of emoji reactions by any given
user produced good user experiences when the results
of the algorithm were used to determine which
emojis got displayed at the top of the picker.

Apoorva got enlisted for the second phase of the
project, in which Zulip intended to use a more
refined algorithm.  Unfortunately, this is the
real world, and sometimes fairly easy decisions
get stalled due to a lot of over-thinking and
trying to reach consensus.

All that Apoorva and I did during the project,
before it got stalled, was to refactor the existing
code.

The original author had a nice implementation, but
it was difficult to unit test, because the model
code was intermingled with UI code.

I actually co-authored a commit to simply extract
the model-specific code into separate functions.
And then Apoorva went to the next step and pulled
all the model-specific code into a new file
called `emoji_frequency_data.ts`.  Here is the
relevant commit:

[emoji_frequency: Move data handling to emoji_frequency_data.ts](https://github.com/zulip/zulip/commit/5a73063a21a4e00d0331b2a5dc964b3520c19f7a#diff-e89b389ac056079bbd670554589663ce3207fbb3e0d386d217c31a8b48910c1cR4-R5)

#### Outcome

The work that Apoorva and I did to re-organize
the code will pay dividends in the future.
It will be easier to unit-test the code, and
it will be easier to do a complete re-write
of the algorithm, as needed, without risk
of breaking the UI interactions surrounding
those calculations.  That's all good.

Unfortunately, that project is stalled for now.

### So what else?

I will write more in future blogs.  So far I have
described the outcomes of two of our projects
that directly pertain to Zulip.

The common theme for both of them is that we
started with prototype code and moved to a cleaner
way of organizing the code.

As a senior developer, one of the most important
things that you can teach younger developers is
the importance of the overall structure of code
within a project.

Just to tease a future blog, I did that with
Apoorva in a completely non-Zulip context. We
wrote a card game together from the ground up.

But that's for later!
