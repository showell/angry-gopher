## Angry Cat Zulip Client

*February 24, 2026*

I have spent most of this month writing my own Zulip
client called Angry Cat.  Here is a screenshot:

![Angry Cat](angry_cat.png)

### history

My first commit to build out the client was on February
10th, so it is officially two weeks old as I write this.

I actually wasn't starting completely from scratch, but
I was pretty close to having a blank slate.

The original code in the repo was written by my colleague Apoorva
Pendse.  We were working on a card game together, and
we wanted to integrate Zulip bots into the game experience.
The card game uses "cat" characters to inform users
of their current score and other things.  We had
a cat we called Angry Cat, and Angry Cat would scold
the user if they weren't able to make a successful play
during their turn.

Here is Angry Cat:

![Angry Cat](mr_angry_cat.png)

And here is the
[repo](https://github.com/showell/angry-cat).

Apoorva built out a convenience app that made it easy
to send messages on behalf of Zulip bots.  This app
had infrastructure to talk to a Zulip server with API
keys from a TypeScript file. It supported fetching
bot data and sending simple messages.

It was called zulip-bot-impersonator but the new repo
is angry-cat (under showell).

I took over the code and decided to build a fairly
general-purpose Zulip client for reading messages.

## Using Angry Cat to catch up on messages

You can see here how I use Angry Cat to manage my backlog of
unread messages from [chat.zulip.org (czo)](https://chat.zulip.org).

![czo screencast](czo_angry_cat.mp4)

<video controls>
  <source src="czo_angry_cat.mp4" type="video/mp4">
</video>

The basic paradigm of Zulip is as follows:
* You join an organization (e.g. czo)
* The org has **channels** that you subscribe to.
* Channels have separate **topics** created by users.
* Each topic has **messages**.

It's really that simple for 95% of what I do on Zulip.

So on Angry Cat I have the following UI:
* The **Channel List** lets me choose a channel.
* The **Topic List** lets me choose a topic.
* The **Message List** show me all the messages on a topic.

This project is very clearly in its early stages, so there
are certain limitations, of course:

* I only download the most recent 5000 messages.
* I don't show message reactions or user avatars yet.
* I don't exclude or indicate which channels and topics I have muted.

The official Zulip client is in its 14th year of development.
I'm in my 14th day. So there is some catching up to do!

Fortunately, I can customize the client to do things that I
really, really need. And then I use my client as a companion
app to the official Zulip client. It works well. I actually
spend about 95% of my working day in Angry Cat.

#### What I do on Angry Cat:

* I browse channels and topics.
* Angry Cat tells me which topics are still unread by me.
* I read the message lists.
* I respond to messages using the "reply" feature.
* When I am done with a topic, I use "mark as read".

Here is a screencast of me replying to a topic:

<video controls>
  <source src="reply_pane.mp4" type="video/mp4">
</video>

Notice as you watch the screencast that there are little
status notifications at the top of the page that tell
me when messages arrive.

#### Try it out!

In order to use Angry Cat, you need a Linux environment.
In my case, I use WSL (Windows Subsystem for Linux), but
it should work on any modern Linux distribution. (I am
testing it on "Ubuntu 22.04.5 LTS" via WSL.)

The application has very few dependencies. It's an HTML
application with a single HTML file called `index.html`:

``` html
<html>
  <head>
    <title>Angry Cat</title>
    <link rel="stylesheet" href="styles/app_variables.css">
    <link rel="stylesheet" href="styles/rendered_markdown.css">
  </head>
  <body>
    <script src="/src/main.ts" type="module"></script>
  </body>
</html>
```

The file `main.ts` is in TypeScript, so you need to transpile
it from TypeScript into JavaScript. Apoorva helped me out
by setting up [vite](https://vite.dev/guide/) as our build
tool.

So, basically do the following:
* go into Linux
* `git clone git@github.com:showell/angry-cat.git`
* cd angry-cat
* follow the instructions in README.md to configure your site url and API key
* install npm and vite
* run `npx vite`
* open up something like `http://localhost:7888/` in the browser (vite will tell you the exact port number)

Obviously, at some point I intend to have a version of the client
running on the web, and it will just have normal Zulip authentication
to connect to your Zulip server of choice.  I'm just not there
yet.  It's actually kind of nice to have it running locally
if you have the proper setup, because you can hack on the code!

The setup should be quick and easy for software developers who
have a bit of familiarity with Linux and node JS.

#### Architecture

As I mentioned earlier, this is just an HTML/JS app with a single
HTML file.  The source code is in `src` and it's all written in
TypeScript and then transpiled to JavaScript by `vite`.

Here is the current version of the main JS entry point, `src/main.ts`:

``` ts
import { EventHandler, ZulipEvent } from "./backend/event";
import * as database from "./backend/database";
import * as zulip_client from "./backend/zulip_client";

import { config } from "./secrets";

import { Page } from "./page";

export async function run() {
    // We overwrite this as soon as we fetch data
    // and call page.start(), which in turn calls
    // into SearchWidget to get the unread counts
    // for our initial download of Zulip data.  But
    // this is nice to have while data is still loading.
    document.title = config.nickname;

    // do before fetching to get "spinner"
    const page = new Page();

    function handle_event(event: ZulipEvent) {
        // We want the model to update before any plugins touch
        // the event.
        database.handle_event(event);

        // The Page object dispatches events to all the plugins.
        page.handle_event(event);
    }

    const event_manager = new EventHandler(handle_event);

    // we wait for register to finish, but then polling goes
    // on "forever" asynchronously
    await zulip_client.register_queue();

    await database.fetch_original_data();

    zulip_client.start_polling(event_manager);

    page.start();
}

run();
```

As you can tell from the imports, there is a "backend" directory
that lives in `src/backend` (relative to the project root).

##### Model code

The code below will help you get started understanding the
data flow.

The "DB" here is just a bunch of JS data structures, to be clear.
My client doesn't have its own back end; **Zulip** itself is the
back end.

``` ts
export let DB: Database;

export type Database = {
    current_user_id: number;
    user_map: Map<number, User>;
    channel_map: Map<number, Stream>;
    topic_map: TopicMap;
    message_map: Map<number, Message>;
};

export async function fetch_original_data(): Promise<void> {
    DB = await fetch.fetch_model_data();
}
```

Here is the fetch code from `src/backend/fetch.ts`:

``` ts
export async function fetch_model_data(): Promise<Database> {
    const users = await fetch_users();

    const user_map = new Map<number, User>();

    let current_user_id = -1;

    for (const user of users) {
        user_map.set(user.id, user);

        if (user.email === config.user_creds.email) {
            current_user_id = user.id;
        }
    }

    const streams = await fetch_streams();

    const channel_map = new Map<number, Stream>();

    for (const stream of streams) {
        channel_map.set(stream.stream_id, stream);
    }

    const topic_map = new TopicMap();

    const rows = await zulip_client.get_messages(BATCH_SIZE);

    const messages: Message[] = rows
        .filter((row: any) => row.type === "stream")
        .map((row: any) => {
            const topic = topic_map.get_or_make_topic_for(
                row.stream_id,
                row.subject,
            );
            const unread =
                row.flags.find((flag: string) => flag === "read") === undefined;
            return {
                id: row.id,
                type: row.type,
                sender_id: row.sender_id,
                topic_id: topic.topic_id,
                stream_id: row.stream_id,
                content: row.content,
                is_super_new: false,
                unread,
            };
        });

    for (const row of rows) {
        if (!user_map.has(row.sender_id)) {
            const id = row.sender_id;
            const email = row.sender_email;
            const full_name = row.sender_full_name;
            const user = { id, email, full_name };
            user_map.set(id, user);
        }
    }

    const message_map = new Map(
        messages.map((message) => [message.id, message]),
    );

    return {
        current_user_id,
        user_map,
        channel_map,
        topic_map,
        message_map,
    };
}
```

If you are familiar with Zulip's actual back end architecture,
you may be surprised to see topic ids. The topic ids are actually
generated on the fly by the client.

Here is an example of where the rubber actually hits the road:

``` ts
export async function get_messages(num_before: number) {
    const url = new URL(`/api/v1/messages`, realm_data.url);
    url.searchParams.set("narrow", `[]`);
    url.searchParams.set("num_before", JSON.stringify(num_before));
    url.searchParams.set("anchor", "newest");
    const response = await fetch(url, { headers: get_headers() });
    const data = await response.json();
    return data.messages;
}
```

Note that I don't even bother with Zulip's official JS bindings
to fetch message data.  I just use native `fetch` and conform to
Zulip's extremely well-documented [REST API](https://zulip.com/api/rest).

#### Some more history (Lyn Rummy)

Before I describe the UI piece of Angry Cat, I will show off my
January app.  Here is what I have done in 2026 so far:

* January: wrote [Lyn Rummy](https://showell.github.io/LynRummy/) (code complete)
* February: wrote Angry Cat (very much a work in progress)

He is a screencast of Lyn Rummy (aka the January app):


<video controls>
  <source src="lynrummy_replay.mp4" type="video/mp4">
</video>

This is the card game that I wrote with some help from Apoorva.
As you can tell, it's a variation of Rummy, and the screencast
shows off a nifty feature of the game, which is that you can
have the app do an "instant replay" of the entire game for you.

Before working on Lyn Rummy, I had spent most of my software
brain power to help develop the official Zulip product, both
on the backend and the frontend. Almost from day one, I was
a "maintenance programmer" and even when I was developing new
features, it was always an exercise of integrating new features
into an application that was already built out.

I simply had never made "play time" to build applications in
either JavaScript or TypeScript. (To be clear, I wasn't
completely idle after work hours.  I wrote a lot of code
in Elm and Python in my spare time.)

In particular, I had never really used TypeScript until my
last year or two of being heavily active as a core developer
in Zulip, and most of that coding was just maintenance in
nature.

Writing Lyn Rummy fueled my passion for how **easily** you
can build browser-based applications in TypeScript. I have
long been a believer of the power of the DOM API that you
get right out of the box, but having the type safety and
code discipline that TS provides amplified my productivity
probably about 10x.

I shouldn't actually say that Lyn Rummy was **easy** to
build.  It went through a lot of iterations.  My final
object architecture for Lyn Rummy is incredibly simple
on the surface, but there was a lot of nuance that evolved
as I found out difficulties in code that I myself had
written. The crutch of TypeScript allowed me to quickly
refactor code into a shape that finally felt simple.

I won't go down the whole rabbit hole of how Lyn Rummy
led me into writing Angry Cat.  I will briefly point out
that the two apps will eventually be integrated in
**both directions** with each other. Chat within a
two-player card game is kinda essential. And having
a two-player card game within your chat client is
just fun! But that's another blog post.

Back to the Angry cat UI.

### Angry Cat User Interface code

I am a minimalist by nature.

Angry Cat has no unnecessary dependencies.  It's 90%
driven by the DOM API for its user interface. There are
no templates (not even JSX) and certainly no jQuery
helpers.  I have an entire directory of pure functions
that just generate DOM with `document.createElement`.
The directory has the clever name of `src/dom`.

Let's look at the navigation bar:

![navbar.png](navbar.png)

The tabs and buttons are crucial to me for how I like
to navigate channels and topics in Zulip. Here is the
code used to render the tab buttons in the nav bar:

``` ts
export function navbar_tab_button(): HTMLButtonElement {
    const button = document.createElement("button");
    button.style.borderBottom = "none";
    button.style.fontSize = "16px";
    button.style.paddingLeft = "13px";
    button.style.paddingRight = "13px";
    button.style.paddingTop = "4px";
    button.style.paddingBottom = "4px";
    button.style.borderTopRightRadius = "10px";
    button.style.borderTopLeftRadius = "10px";

    return button;
}

function add_search_button(add_search_widget: () => void): HTMLDivElement {
    const div = document.createElement("div");
    div.style.marginRight = "15px";

    const button = document.createElement("button");
    button.innerText = "+";
    button.style.backgroundColor = "white";
    button.style.padding = "3px";
    button.style.fontSize = "12px";
    button.style.backgroundColor = "white";
    button.style.border = "1px green solid";

    button.addEventListener("click", () => {
        add_search_widget();
    });

    div.append(button);

    return div;
}

function tab_bottom_border_spacer(): HTMLDivElement {
    const spacer = document.createElement("div");
    spacer.innerText = " ";
    spacer.style.borderBottom = "1px black solid";
    spacer.style.height = "1px";
    spacer.style.flexGrow = "1";

    return spacer;
}

function make_button_bar(
    tab_button_divs: HTMLDivElement[],
    add_search_widget: () => void,
): HTMLDivElement {
    const button_bar = document.createElement("div");
    button_bar.style.display = "flex";
    button_bar.style.alignItems = "flex-end";
    button_bar.style.paddingTop = "2px";
    button_bar.style.marginBottom = "3px";
    button_bar.style.maxHeight = "fit-content";

    button_bar.append(add_search_button(add_search_widget));

    for (const tab_button_div of tab_button_divs) {
        button_bar.append(tab_button_div);
    }

    button_bar.append(tab_bottom_border_spacer());

    return button_bar;
}

export function render_navbar(
    status_bar_div: HTMLDivElement,
    tab_button_divs: HTMLDivElement[],
    add_search_widget: () => void,
) {
    const navbar_div = document.createElement("div");
    navbar_div.append(status_bar_div);
    navbar_div.append(make_button_bar(tab_button_divs, add_search_widget));
    navbar_div.style.position = "sticky";
    navbar_div.style.marginTop = "8px";
    navbar_div.style.marginLeft = "8px";
    navbar_div.style.top = "0px";
    navbar_div.style.zIndex = "100";
    navbar_div.style.backgroundColor = "rgb(246, 246, 255)";

    return navbar_div;
}
```

I don't even use CSS to style them. The DOM API lets you set
all the styles that I needed to make it look nice. (*As a quick
aside, I do actually use some CSS in the app. I only use CSS
to style message content for each message in the message list.
I borrowed that code 100% verbatim from the official client.*)

#### Composability through functions

When your entire codebase is driven by TypeScript functions and
classes, it is extremely easy to do the following things:

* I can refine **everything** about a "leaf" component with one-stop shopping.
* I don't have to worry about breaking other components (i.e. I avoid the CSS pitfall).
* I can let TypeScript enforce the protocols for how parents interact with their children (and vice versa).

It's honestly laughable how simple things are at times.

#### Plugins

Let's look at the navigation bar again:

![navbar.png](navbar.png)


All of the tabs are driven by a Plugin architecture. I
mentioned earlier that I render the tab buttons themselves
with pure functions that use the DOM API. Of course,
the guts of a plugin are in the main container of the page.

You code your plugin and then the integration code is pretty
simple. Note how the `PluginChooser` has a click handler
below that launches the `EventRadio` plugin. (*As an aside,
the PluginChooser is itself a plugin!*)

```
import type { ZulipEvent } from "../backend/event";
import type { PluginHelper } from "../plugin_helper";

import { EventRadio } from "./event_radio";

export class PluginChooser {
    div: HTMLDivElement;

    constructor() {
        const div = document.createElement("div");
        this.div = div;
    }

    start(plugin_helper: PluginHelper): void {
        const div = this.div;

        div.innerText = "We only have one plugin so far!";

        const button = document.createElement("button");
        button.innerText = "Launch event radio";
        button.addEventListener("click", () => {
            const event_radio = new EventRadio();
            plugin_helper.add_plugin(event_radio);
        });

        div.append(button);

        plugin_helper.update_label("Plugins");
    }

    handle_event(_event: ZulipEvent): void {
        // nothing to do
    }
}
```

Here is how you expect a plugin to behave:

``` ts
 16 export type Plugin = {
 17     div: HTMLElement;
 18     start: (plugin_helper: PluginHelper) => void;
 19     handle_event: (event: ZulipEvent) => void;
 20 };
```

Every plugin just needs to hand off a `div` to its parent. The
grandparent div is the `container_div` in the `Page` object:

``` ts
class Page {
    // ...
    redraw(plugin_helper: PluginHelper): void {
        // ...

        const container_div = page_widget.render_container();
        container_div.append(plugin_helper.plugin.div);

        div.innerHTML = "";
        div.append(navbar_div);
        div.append(container_div);
    }

    // ...
}
```

Every plugin uses the `PluginHelper` protocol to talk to its parents:

``` ts
export class PluginHelper {
    deleted: boolean;
    page: Page;
    open: boolean;
    plugin: Plugin;
    label: string;
    tab_button: TabButton;
    model: Model;

    constructor(plugin: Plugin, page: Page) {
        this.plugin = plugin;
        this.page = page;
        this.deleted = false;
        this.open = false;
        this.label = "plugin";
        this.tab_button = new TabButton(this, page);
        this.model = new Model();
    }

    delete_me(): void {
        this.deleted = true;
        this.page.remove_deleted_plugins();
        this.page.go_to_top();
    }

    refresh() {
        this.tab_button.refresh();
    }

    update_label(label: string) {
        this.label = label;
        this.refresh();
    }

    violet() {
        this.tab_button.violet();
    }

    add_plugin(plugin: Plugin): void {
        this.page.add_plugin(plugin);
    }
}
```

The `SearchWidget` plugin is the most important plugin written so far,
as it really governs about 95% of the utility of the app now.  The
`SearchWidget` plugin lets you navigate through the channel/topic/message
hierarchy, and it also orchestrates opening a compose box when you either
want to reply to a message list or add a new topic for a channel.

It gets a tiny bit of first-class treatment.  For example, `Page.start`
always makes sure we have a tab open with a virgin `SearchWidget`
instance that is ready to use (and then the user can add more by
clicking on the "+" button in the navbar):

``` ts
 36     start(): void {
 37         const plugin_chooser = new PluginChooser();
 38         this.add_plugin(plugin_chooser);
 39
 40         this.add_search_widget();
 41         this.update_title();
 42     }
```

We will use it as our example to show how plugins call back to
the `PluginHelper` object.

Below is the code where a `SearchWidget` instance
updates the unread counts for its tab button.

(*Just to be clear, there may be, and usually are, multiple
instances of `SearchWidget` running.*)

``` ts
    update_label(): void {
        this.plugin_helper!.update_label(this.get_narrow_label());
    }

    get_narrow_label(): string {
        const channel_name = this.get_channel_name();
        const topic_name = this.get_topic_name();
        const unread_count = this.unread_count();

        return narrow_label(channel_name, topic_name, unread_count);
    }
```

The above two methods are inside the `SearchWidget` class.

The following pure function is at module level. I try to extract
pure functions as much as possible:

```
function narrow_label(
    channel_name: string | undefined,
    topic_name: string | undefined,
    unread_count: number,
): string {
    let label: string;

    if (topic_name !== undefined) {
        label = "> " + topic_name;
    } else if (channel_name !== undefined) {
        label = "#" + channel_name;
    } else {
        label = "Channels";
    }

    const prefix = unread_count === 0 ? "" : `(${unread_count}) `;

    return prefix + label;
}
```

#### SearchWidget and Panes

We talked about how `SearchWidget` talks to its "outer"
world using the `PluginHelper` class.

Let's peek inside its implementation.

The Zulip paradigm, at its core, comes down to three
concepts:

* channels
* topics
* messages

In the `SearchWidget` UI, these concepts manifest as panes.

Look at the three top-level widgets in this screenshot
(below the navbar and buttons to be clear):

![panes.png](panes.png)

The panes are these:

* Channel Chooser
* Topic Chooser (for "#Angry Cat" channel)
* Message list (for "> tab discipline" topic)

Each of the three panes (and panes in general) follow a simple protocol:

``` ts
type PaneWidget = {
    div: HTMLElement;
};

type Pane = {
    key: string;
    pane_widget: PaneWidget;
};
```

It's literally that simple to be a pane. You need to have
a div.

Here is some example code from `SearchWidget` that is a
little bit more complex:

```
    clear_channel(): void {
        this.get_channel_list().clear_selection();
        this.pane_manager.remove_after("channel_pane");
        this.channel_view = undefined;
        this.update_button_panel();
        this.button_panel.focus_next_channel_button();
        this.update_label();
        StatusBar.inform("You can choose a channel now.");
    }
```

When you click on a selected item within the channel chooser,
that click effectively de-selects the particular channel.

At that point we want the topic list (and possibly a message
list) to go away.

By virtue of calling `this.pane_manager.remove_after("channel_pane");`,
the UI will subsequently look like this:

![just_channels.png](just_channels.png)

We just let `pane_manager.remove_after` manage the redraw process
(in a completely generic way, of course):

``` ts
    remove_after(key: string) {
        const new_panes = [];

        for (const pane of this.panes) {
            new_panes.push(pane);
            if (pane.key === key) {
                break;
            }
        }

        this.panes = new_panes;
        this.redraw();
    }

    redraw(): void {
        // TODO: adjust to screen size
        const div = this.div;
        const panes = this.panes;

        div.innerHTML = "";
        for (const pane of panes) {
            div.append(pane.pane_widget.div);
        }
    }
```

Right now the `PaneManager` class just always sticks
the panes in a flex div, but of course, as the `TODO`
above suggests, it would be trivial to provide alternative
renderings of the panes for a more responsive design.

Here is the code to create the outer div that the panes
get attached to. (And then up both the object tree and
the DOM tree, the div here eventually goes into
`SearchWidget.div` and eventually `Page.container_div`.)

``` ts
export class PaneManager {
    div: HTMLElement;
    panes: Pane[];

    constructor() {
        const div = document.createElement("div");
        div.style.display = "flex";

        this.div = div;
        this.panes = [];
    }

    // ...
}
```

#### The channel pane

Let's look at how the channel pane gets rendered. Here
it is again for reference:

![just_channels.png](just_channels.png)

Here is the `ChannelPane` class in its entirety:

``` ts
export class ChannelPane {
    div: HTMLElement;
    channel_list: ChannelList;

    constructor(search_widget: SearchWidget) {
        const div = render_pane();

        this.channel_list = new ChannelList(search_widget);

        this.div = div;
        this.populate();
    }

    channel_selected(): boolean {
        return this.channel_list.has_selection();
    }

    get_channel_list(): ChannelList {
        return this.channel_list;
    }

    populate() {
        const div = this.div;
        const channel_list = this.channel_list;

        channel_list.populate();

        div.innerHTML = "";
        div.append(render_list_heading("Channels"));
        div.append(channel_list.div);
    }
}
```

It includes a `ChannelList` object. That class does some logic
to manage click events and to respond to the "next channel"
and "surf channels" buttons. I will omit those details for
brevity, but you can read `channel_list.ts` in the repo.

Here is where the `ChannelList` object creates the table
of channels:

``` ts
    make_table(): HTMLElement {
        const search_widget = this.search_widget;
        const cursor = this.cursor;
        const row_widgets = [];

        const channel_rows = this.get_channel_rows();

        for (let i = 0; i < channel_rows.length; ++i) {
            const channel_row = channel_rows[i];
            const selected = cursor.is_selecting(i);
            const row_widget = channel_row_widget.row_widget(
                channel_row,
                i,
                selected,
                search_widget,
            );
            row_widgets.push(row_widget);
        }

        const columns = ["Unread", "Channel", "Topics"];
        return table_widget.table(columns, row_widgets);
    }
```

The `table_widget.table` function is pure DOM:

``` ts
import { render_th, render_thead, render_tr } from "./render";

export type RowWidget = {
    divs: HTMLDivElement[];
};

export function table(
    columns: string[],
    row_widgets: RowWidget[],
): HTMLTableElement {
    function make_tbody(): HTMLTableSectionElement {
        const tbody = document.createElement("tbody");

        for (const row_widget of row_widgets) {
            tbody.append(render_tr(row_widget.divs));
        }

        return tbody;
    }

    const thead = render_thead(columns.map((col) => render_th(col)));
    const tbody = make_tbody();

    const table = document.createElement("table");
    table.append(thead);
    table.append(tbody);

    table.style.borderCollapse = "collapse";

    return table;
}
```

#### UI architecture summary

I didn't cover every single component or aspect of the UI,
but I can summarize it as follows:

* The Page object builds the navbar and the main container
* The PluginHelper orchestrates the tab-based UI.
* The main plugin is SearchWidget.
* SearchWidget uses PaneManager to arrange these objects:
    * ChannelPane
    * ChannelInfo
    * TopicPane
    * MessagePane
    * ReplyPane
    * AddTopicPane

The FooPane objects can include any components that they
want, but to give a concrete hierarchy:

* TopicPane
    * TopicList
        * (data) TopicRow[]
        * (pure function) dom/table_widget.ts: table()
        * Cursor

I didn't talk much about click handlers and callbacks, but
you can read the code to see the paradigm there.

We only have three plugins so far:

* SearchWidget (with ChannelPane, TopicPane, MessagePane, etc.)
* PluginChooser
* EventRadio

Soon to come:

* buddy list
* recent conversations
* code search
* (etc.)

#### other stuff

I didn't really cover event handling or live updates, but
the model there is quite simple too.  Here is an example
event handler from `SearchWidget`:

``` ts
    handle_event(event: ZulipEvent): void {
        if (event.flavor === EventFlavor.MESSAGE) {
            this.handle_incoming_message(event.message);
        }

        if (event.flavor === EventFlavor.MUTATE_MESSAGE) {
            this.refresh_message_ids([event.message_id]);
        }

        if (event.flavor === EventFlavor.MUTATE_UNREAD) {
            this.refresh_message_ids(event.message_ids);
        }

        this.update_label();
    }
```

Here is the entire codebase as of February 24, 2026:

``` ts
$ find . -name '*.ts' | sort | xargs wc -l
    45 ./add_topic_pane.ts
    40 ./backend/channel_row_query.ts
    65 ./backend/database.ts
    31 ./backend/db_types.ts
   132 ./backend/event.ts
   107 ./backend/fetch.ts
    31 ./backend/filter.ts
    52 ./backend/message_list.ts
    82 ./backend/model.ts
    57 ./backend/outbound.ts
    35 ./backend/topic_map.ts
    33 ./backend/topic_row_query.ts
    73 ./backend/zulip_client.ts
    60 ./button.ts
    58 ./channel_info.ts
   161 ./channel_list.ts
    38 ./channel_pane.ts
   215 ./channel_view.ts
   125 ./compose.ts
    46 ./cursor.ts
    69 ./dom/channel_row_widget.ts
    43 ./dom/compose_widget.ts
    92 ./dom/page_widget.ts
    96 ./dom/render.ts
    31 ./dom/table_widget.ts
    75 ./dom/topic_row_widget.ts
    42 ./main.ts
    67 ./message_content.ts
   148 ./message_list.ts
    33 ./message_pane.ts
    34 ./message_popup.ts
    83 ./message_row_widget.ts
    48 ./message_view.ts
    41 ./message_view_header.ts
   128 ./nav_button_panel.ts
   152 ./page.ts
    94 ./pane_manager.ts
   108 ./plugin_helper.ts
    68 ./plugins/event_radio.ts
    34 ./plugins/plugin_chooser.ts
    94 ./popup.ts
     8 ./render.ts
    38 ./reply_pane.ts
   179 ./row_types.ts
   339 ./search_widget.ts
    79 ./secrets.ts
    10 ./server.ts
   129 ./smart_list.ts
    38 ./status_bar.ts
   165 ./topic_list.ts
    34 ./topic_pane.ts
  4085 total
```

#### Future directions

I am already up to using Angry Cat for 95% of my Zulip-based
work. I use Zulip every single day of development. I am not
only developing Angry Cat itself, but I am helping Apoorva
with his contributions to the core Zulip product.  We are
absolutely power users of the Zulip server, and I am very
happy using the Cat as my client.

I feel like I have a pretty good architectural foundation now
to build out features.  I basically prioritize features by
being annoyed.  If I can't do something with Angry Cat, I try
to work around it within the app.  If I need to go to the
official Zulip client for the same thing over and over again,
I eventually build it.

I will blog more soon! Feedback is welcome.
