## Friday the 13th: Try my luck!

*March 13, 2026*

I want to work on something experimental today,
so let's brainstorm a bit:

#### mini file system in Zulip

This is a pretty easy to component to write. You
make a virtual file system that sits on top of Zulip.
Basically every file is a Zulip message with a little
address at the top such as `steve/pictures`, and you
auto-create folders.

Then in Angry Cat you simulate a little version of
File Manager, and you add the ability to save ordinary
Zulip messages from your regular feeds to the file
system.

The whole view of the world just gets computed every
time by reading a bunch of messages from a special
`__file_system__` topic inside of any given channel.
(If you want your files to be private, create a private
channel; unlike Unix, you can't chmod files, they will
all inherit the permission level of the channel.)


#### Roc bindings to Zulip

These are pretty self-explanatory.

#### HTML parsers

I haven't written an HTML parser in a while.  I could do
it Roc to learn Roc, or I could do it in JS to practice some
data-oriented coding.

#### Handle images better in Angry Cat

I should look at the actual dimensions of the image before
fetching temporary URLs from Zulip and create some dummy
divs that match the image size so that scrolling works
naturally even while we might have to wait for the server
to hyrdate the images.

#### Extract emoji list from czo

Maybe go back through 100k messages on czo to get the
list of emojis that are actually used on a real world
realm.

Or maybe just ask Apoorva to get them from running
Zulip's script.

### Try out datastar SSE concept with Zulip

Write a tiny little proxy that just supports an extended
SSE-like HTTP connection to the proxy (and let the proxy
do normal backend stuff with Zulip).

### Write a Zulip Django-admin-app-like personal client

Just write something really raw that works one table at a
time.

#### Write actual data-start code.

Just figure out the TS bindings for data-star.

See [bindings here](https://github.com/starfederation/datastar-typescript).

#### Think about other MPA (multi-page application) approaches

I think the MPA approach is to just have each type of endpoint
work with an associated JS snippet that does the event loop.
