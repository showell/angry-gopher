## Angry Cat progress

*March 7, 2026*

Today is Saturday, and I believe all of the following
milestones were achieved this week:

* We now host Angry Cat on GH pages.
* Users can permanently connect to Zulip after a one-time login
* We have renamed the repo as showell/angry-cat.
* We can run Lyn Rummy inside of Angry Cat.
* Lyn Rummy serializes every event to a Zulip channel.

There are a couple immediate goals:
* We need to fix a small bug related to external links.
* We need to continue the Lyn Rummy integration on the "read" side.
* We need to continue to make Angry Cat users completely self-sufficient.

#### Lyn Rummy integration

We now serialize every Lyn Rummy event to the "Lyn Rummy" channel
on the macandcheese realm. (We will eventually make stuff work on
other realms too, of course.)

I next need to make it so that somebody can effectively watch another
player play Lyn Rummy in solitaire mode.  This means that I should
be able to find the messages that are already being serialized now
to the Lyn Rummy channel, choose which game I want to watch or review
(whether in real time or after the fact), and then have Lyn Rummy
replay the events from that game.

And then once all that works, it's a pretty small step to having two
players play the same game.  We need to coordinate the start of the
game, and then we need a little bit of code to manage the turns. To
some degree we will probably be lenient about turns and let the players
manage that themselves.  In other words Susan might be free to make
moves even when it's Lyn's turn, simply because Lyn had to leave the
game, or maybe Lyn wanted a little help from Susan.  And we would just
try to make those interventions obvious to both players.  I haven't
though deeply about turn mechanics yet.

Another thing I want to do with the Lyn Rummy integration is to set
the stage for future apps, including the native Zulip poll.  So I may
end up stealing some ideas from the
[webxdc project](https://webxdc.org/docs/spec/api.html) and at least
use their naming conventions:

* sendUpdate
* setUpdateListener


#### Login

Users can now log in to Angry Cat in a one-time setup where they
enter their API key for the macandcheese realm.  We save the API
key to localstorage.

I still eventually want to cut over to using actual passwords at
some point.

#### Avoiding to need the Legacy Client

I really use Angry Cat for 99% of what I do now when it comes
to macandcheese. Here are a couple things that would get me closer
to 100%:

* add an attach-file button (we have all the upload code, so this
shouldn't be too hard)
* handle incoming changes to channel names and descriptions
* make it easy to edit channel names and descriptions
* allow users to edit messages

I just started a topic under Angry Cat called "Legacy Client log".

#### Code cleanup

I extracted a new API for "channel chooser" components earlier in
the week.  I want to continue to make sure that nearly every
component in the system is pluggable in some sense.

#### Long term effort

I want to mostly get toward a mode where I spend maybe an hour a
day on Angry Cat to incrementally improve it.  There are still
gonna be some sessions that are more on the magnitude of days
than hours, such as integrating Lyn Rummy.
