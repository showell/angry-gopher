## Four days of Zig

*March 30, 2026*

I spent the last four days ramping up on zig.  I basically started from
zero, unless you count a few random hours leading up to it where
I read some docs and listened to some podcasts about it.

I like zig.

### Zig lets you do abstractions

Like all low-level languages, Zig requires a little more work to
do "simple" things, but you can build up abstractions.

Almost every app has data that could be reasonably modeled
by a relational database.  Even if you are not using an actual
external database, it's helpful to think in those terms.

An example database concept is that you often have entities
that form a one-to-many relationship.  Here is how I express that
in zig:

``` zig
const std = @import("std");

const Int = u32;
const Map = std.AutoHashMap;
const List = std.ArrayList;
const IntSet = Map(Int, void);
const Allocator = std.mem.Allocator;

pub const OneToMany = struct {
    allocator: Allocator,
    list_of_sets: List(IntSet),

    pub fn update(
        self: *OneToMany,
        one_index: Int,
        many_index: Int,
    ) !void {
        const allocator = self.allocator;
        var list_of_sets = &self.list_of_sets;

        // Note that we expect our `one_index` values to be contiguous
        // values starting from zero (hence the underlying ArrayList), but
        // they are allowed to grow.
        while (one_index >= list_of_sets.items.len) {
            try list_of_sets.append(allocator, IntSet.init(allocator));
        }

        var many_index_set = list_of_sets.items[one_index];
        try many_index_set.put(many_index, {});
        list_of_sets.items[one_index] = many_index_set;
    }

    pub fn get_many_indexes(
        self: OneToMany,
        allocator: Allocator,
        one_index: Int,
    ) !List(Int) {
        const index_set = self.list_of_sets.items[one_index];

        const len = index_set.count();
        var indexes = try List(Int).initCapacity(allocator, len);

        var it = index_set.keyIterator();

        while (it.next()) |index_ptr| {
            try indexes.append(allocator, index_ptr.*);
        }

        return indexes;
    }

    pub fn count(self: OneToMany, one_index: Int) Int {
        return self.list_of_sets.items[one_index].count();
    }

    pub fn init(allocator: Allocator) OneToMany {
        return OneToMany{
            .allocator = allocator,
            .list_of_sets = .empty,
        };
    }

    pub fn deinit(
        self: *OneToMany,
    ) void {
        const allocator = self.allocator;
        var list_of_sets = self.list_of_sets;

        for (list_of_sets.items) |*index_set| {
            index_set.deinit();
        }
        list_of_sets.deinit(allocator);
    }
};
```

I'm not going to go into tremendous detail how this code
gets used, but it's as simple as this:

* define some structs
* store them in ArrayList objects and keep track of the integer indexes
* keep track of one-to-many relationships with the above `OneToMany` mechanism
* call `get_many_indexes` when your reading code needs to traverse a one-to-many relationship

You don't have any performance disasters where you need to traverse some huge
data structure to go from a single `address_index` to many `message_index` indexes.

You just do this at write time:

``` zig
    // ADDRESS -> set of MESSAGE
    try db.one_to_many_address_to_message.update(
        address_index,
        message_index,
    );
```

And then do this at read time:

``` zig
    var indexes = try db.one_to_many_address_to_message.get_many_indexes(
        allocator,
        address_index,
    );
    defer indexes.deinit(allocator);

    const len = indexes.items.len;

    var rows = try List(MessageRow).initCapacity(allocator, len);

    for (indexes.items) |index| {
        try rows.append(allocator, db.message_rows.items[index]);
    }
```

### Memory allocation

It's not that hard to get memory allocation right if you just
think about the lifetime of objects.

Zig implements a concept called arena allocation, where you can
have an allocator that lives in the natural "cycle" of an application,
and you don't have to granularly free any data.  Instead, you just
allocate data to the the heap as you need it, and when you finish
the cycle, you just tell the arena allocator to clean up everything.

But I didn't even need to do that.

All you do is just make sure that there's a proper concept of
ownership that makes sense for the life-cycle of the object.

In my app I inherit some strings that refer to a "topic" in Zulip.
For the purpose of discussion it doesn't matter that you understand
what Zulip is (it's an office-chat system) nor what a topic is
within Zulip (it's just a category for the message).

When topics come in from the outside world, I store them in my
"database".  And I just store them like this:

``` zig
    if (db.topic_string_index_map.get(topic_name)) |index| {
        return index;
    } else {
        const new_index = db.topic_strings.items.len;

        {
            const our_topic_name = try db.allocator.dupe(u8, topic_name);
            try db.topic_strings.append(db.allocator, our_topic_name);
            try db.topic_string_index_map.put(our_topic_name, new_index);
        }

        return new_index;
    }
```

Note the call to dupe there.  That makes a copy of the string that
**my code owns**.  I actually use the string in two places, but I only
need to de-allocate it once.

And the deallocation code is as simple as this:

``` zig
    for (db.topic_strings.items) |topic_name| {
        db.allocator.free(topic_name);
    }
```

The above code excecutes when I call `deinit` by the enclosing data
structure, which I call `Database`.

It's super easy to verify this with test code like this:

```
test "database" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var db = Database.init(allocator);
    defer db.deinit();

    // do a bunch of stuff with Database
}
```

If there are any memory leaks, then zig will properly squawk
at me and tell me what a loser I am if I don't get the memory
management correct.

Notice the call to `defer db.deinit()` there. That's the code
that frees the memory when I am done using the database. And it
just traverses `db.topic_strings.items` (among other things) to
free up all the heap memory related to `db.topic_strings`. It's
as simple as that.

#### Zig performs great

I have a data structure that maps channels to topics to messages
in a basic data hierarchy.

I loaded up my memory with 10 million messages. Each topic has
25,000 messages attached to it.

It takes about 12 milliseconds for zig to grab a batch of 25,000
messages from those 10 million messages and turn them into HTML.
(It uses the aformentioned `OneToMany` class under the hood.)

I ran my performance test for a billion records, and it took a
little under an hour and a half.

``` zig
const std = @import("std");
const database = @import("./database.zig");
const html = @import("./html.zig");
const server_types = @import("./server_types.zig");

const Database = database.Database;
const ChannelRow = database.ChannelRow;
const TopicRow = database.TopicRow;
const MessageRow = database.MessageRow;

const ServerSubscription = server_types.ServerSubscription;
const ServerMessage = server_types.ServerMessage;

const Allocator = std.mem.Allocator;
const List = std.ArrayList;

const Int = u32;
const Str = []const u8;

fn test_html_for_channel(
    db: Database,
    allocator: Allocator,
    channel_index: Int,
) !void {
    {
        const s = try html.topics_html(
            db,
            allocator,
            channel_index,
        );
        defer allocator.free(s);
    }

    var topic_rows = try db.get_topic_rows_for_channel_index_by_name(
        allocator,
        channel_index,
    );
    defer topic_rows.deinit(allocator);

    for (topic_rows.items) |topic_row| {
        const s = try html.messages_html(
            db,
            allocator,
            topic_row.address_index,
        );
        defer allocator.free(s);
    }
}

fn test_html(
    db: Database,
    allocator: Allocator,
) !void {
    const s = try html.channels_html(db, allocator);
    defer allocator.free(s);

    var channel_rows = try db.get_channel_rows_by_name(allocator);
    defer channel_rows.deinit(allocator);

    for (channel_rows.items) |channel_row| {
        const channel_index = channel_row.index;

        try test_html_for_channel(
            db,
            allocator,
            channel_index,
        );
    }
}

pub fn main() !void {
    // var gpa = std.heap.DebugAllocator(.{}){};
    // defer _ = gpa.deinit();
    // const allocator = gpa.allocator();

    const allocator = std.heap.smp_allocator;

    var db = Database.init(allocator);
    defer db.deinit();

    const nums: [20]Int = .{ 17, 11, 4, 6, 14, 2, 9, 12, 1, 13, 19, 15, 5, 7, 10, 3, 8, 16, 18, 0 };

    for (nums) |n| {
        const channel_id = 100 + n;
        const name = try std.fmt.allocPrint(
            allocator,
            "channel-{d}",
            .{channel_id},
        );
        defer allocator.free(name);

        const subscription = ServerSubscription{
            .stream_id = channel_id,
            .name = name,
        };
        try db.process_server_subscription(subscription);
    }

    var message_id: Int = 10000;

    for (0..25_000) |_| {
        for (nums) |n| {
            const channel_id = 100 + n;

            for (nums) |topic_n| {
                const subject = try std.fmt.allocPrint(
                    allocator,
                    "topic_{d}",
                    .{1000 + topic_n},
                );
                defer allocator.free(subject);

                message_id += 1;

                const content = try std.fmt.allocPrint(
                    allocator,
                    "content {d}",
                    .{message_id},
                );
                defer allocator.free(content);

                const message = ServerMessage{
                    .content = content,
                    .id = message_id,
                    .sender_full_name = "Foo Barson",
                    .sender_id = 1001,
                    .subject = subject,
                    .stream_id = channel_id,
                };

                try db.process_server_message(message);
            }
        }

        const count = db.total_message_count();
        if (count % 10_000 == 0) {
            std.log.info("{d} messages", .{count});
        }
    }

    for (0..100) |i| {
        try test_html(db, allocator);
        std.log.debug("output another round of messages {d}", .{i});
    }
}
```

Note this code:

``` zig
    // var gpa = std.heap.DebugAllocator(.{}){};
    // defer _ = gpa.deinit();
    // const allocator = gpa.allocator();

    const allocator = std.heap.smp_allocator;
```

You have to use the right allocator in your benchmarks.  I comment
out the `DebugAllocator` for benchmarks, but before I run the benchmarks,
I use the `DebugAllocator` (plus smaller loops) to verify that I don't
have leaks.

I let the program run long enough to serizalize a BILLION messages.
It's all fine.

### Testing

Zig's testing system is easy to use, and it catches memory leaks as well.

Here is an example test that I wrote.

``` zig

test "html" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var db = Database.init(allocator);
    defer db.deinit();

    try db.process_server_subscription(ServerSubscription{ .stream_id = 102, .name = "design" });
    try db.process_server_subscription(ServerSubscription{ .stream_id = 103, .name = "feedback" });
    try db.process_server_subscription(ServerSubscription{ .stream_id = 101, .name = "engineering" });
    try db.process_server_subscription(ServerSubscription{ .stream_id = 103, .name = "this-gets-ingored" }); // dup id

    const message1 = ServerMessage{
        .content = "message1",
        .id = 201,
        .sender_full_name = "Foo Barson",
        .sender_id = 1001,
        .subject = "design stuff",
        .stream_id = 102,
    };

    const message2 = ServerMessage{
        .content = "message2",
        .id = 202,
        .sender_full_name = "Foo Barson",
        .sender_id = 1001,
        .subject = "design stuff",
        .stream_id = 102,
    };

    const message3 = ServerMessage{
        .content = "message3",
        .id = 203,
        .sender_full_name = "Fred Flintstone",
        .sender_id = 1002,
        .subject = "feedback & other stuff",
        .stream_id = 101,
    };

    const message4 = ServerMessage{
        .content = "message4",
        .id = 204,
        .sender_full_name = "Fred Flintstone",
        .sender_id = 1002,
        .subject = "another design topic",
        .stream_id = 102,
    };

    try db.process_server_message(message1);
    try db.process_server_message(message2);
    try db.process_server_message(message3);
    try db.process_server_message(message4);

    std.testing.log_level = .debug;
    {
        const html = try channels_html(db, allocator);
        defer allocator.free(html);
        std.log.debug("html:\n{s}", .{html});
    }

    var channel_rows = try db.get_channel_rows_by_name(allocator);
    defer channel_rows.deinit(allocator);

    for (channel_rows.items) |channel_row| {
        const channel_index = channel_row.index;
        {
            const html = try topics_html(db, allocator, channel_index);
            defer allocator.free(html);
            std.log.debug("html:\n{s}", .{html});
        }

        var topic_rows = try db.get_topic_rows_for_channel_index_by_name(
            allocator,
            channel_index,
        );
        defer topic_rows.deinit(allocator);

        for (topic_rows.items) |topic_row| {
            const address_index = topic_row.address_index;
            {
                const html = try messages_html(
                    db,
                    allocator,
                    address_index,
                );
                defer allocator.free(html);
                std.log.debug("html:\n{s}", .{html});
            }
        }
    }
}
```
