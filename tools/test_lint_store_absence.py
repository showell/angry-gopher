#!/usr/bin/env python3
"""Tests for tools/lint_store_absence.py.

A lint that never fires is indistinguishable from a clean tree, so every form
it refuses is shown FIRING on a synthetic tree, and every form it lets pass is
shown HOLDING.

    python3 tools/test_lint_store_absence.py

Run by ops/check_zig, before the lint itself.
"""
import os
import sys
import tempfile
import textwrap
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lint_store_absence as L  # noqa: E402


class Tree:
    """A throwaway zig-server/src with the files given, as {name: source}."""

    def __init__(self, files):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name
        files = {"store.zig": "pub fn read() void {}\n", **files}
        for name, body in files.items():
            with open(os.path.join(self.dir, name), "w", encoding="utf-8") as f:
                f.write(textwrap.dedent(body))

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.tmp.cleanup()

    def lines(self):
        return [(name, n) for name, n, _ in L.scan(self.dir)]


def one(body, name="a.zig", alias="store"):
    """A file that imports store.zig as `alias`, with `body` after it."""
    return {name: f'const {alias} = @import("store.zig");\n' + textwrap.dedent(body)}


class Fires(unittest.TestCase):
    def test_each_value_a_failure_is_caught_into(self):
        for handler in ['""', "return 0", "return null", "null", "{}", "continue",
                        "return", "false", "0", "break", "return .{}", "|_| null"]:
            with self.subTest(handler=handler), Tree(one(f"""\
                fn f() void {{
                    const x = store.read(io, a, p, .unlimited) catch {handler};
                }}
            """)) as t:
                self.assertEqual(t.lines(), [("a.zig", 3)])

    def test_every_read_the_store_has(self):
        for fn in ["read", "readOrEmpty", "readAt", "stat", "has", "list"]:
            with self.subTest(fn=fn), Tree(one(f"""\
                fn f() void {{
                    _ = store.{fn}(io, a, p) catch null;
                }}
            """)) as t:
                self.assertEqual(t.lines(), [("a.zig", 3)])

    def test_under_any_name_the_file_gives_the_store(self):
        with Tree(one("""\
            fn f() void {
                _ = disk.stat(io, a, p) catch return 0;
            }
        """, alias="disk")) as t:
            self.assertEqual(t.lines(), [("a.zig", 3)])

    def test_a_call_over_several_lines_is_found_at_its_start(self):
        with Tree(one("""\
            fn f() void {
                const raw = store.read(
                    io,
                    alloc,
                    path, // a comment with ( in it
                    .unlimited,
                ) catch "";
            }
        """)) as t:
            self.assertEqual(t.lines(), [("a.zig", 3)])

    def test_a_comment_after_the_call_does_not_defend_it(self):
        with Tree(one("""\
            fn f() void {
                const raw = store.read(io, a, p, .unlimited) catch ""; // why
            }
        """)) as t:
            self.assertEqual(t.lines(), [("a.zig", 3)])


    def test_an_if_whose_error_is_dropped(self):
        # counter.zig's next: an unreadable counter was a fresh one.
        with Tree(one("""\
            fn f() !i64 {
                var n: i64 = 0;
                if (store.read(io, a, p, .limited(64))) |body| {
                    n = parse(body);
                } else |_| {}
                if (store.stat(io, a, p)) |st| n += st.size else |_| n = 0;
                return n;
            }
        """)) as t:
            self.assertEqual(t.lines(), [("a.zig", 4), ("a.zig", 7)])


    def test_a_comment_that_is_not_a_defence(self):
        # admin_lynrummy.zig:188 passed on a comment about something else.
        for comment in ["// Total actions = nonempty lines in actions.dsl.", "// absent-ok:", "// absent-ok"]:
            with self.subTest(comment=comment), Tree(one(f"""\
                fn f() i64 {{
                    {comment}
                    const raw = store.read(io, a, p, .unlimited) catch return 0;
                }}
            """)) as t:
                self.assertEqual(t.lines(), [("a.zig", 4)])

    def test_a_named_error_made_a_value(self):
        for handler in ["|e| { log(e); return null; }", "|err| return null", "|e| switch (e) { else => \"\" }",
                        "|e| blk: { _ = e; break :blk 0; }"]:
            with self.subTest(handler=handler), Tree(one(f"""\
                fn f() !?[]u8 {{
                    const raw = store.read(io, a, p, .unlimited) catch {handler};
                    return raw;
                }}
            """)) as t:
                self.assertEqual(t.lines(), [("a.zig", 3)])

    def test_a_switch_that_makes_another_failure_a_value(self):
        # metal-vmm QUEUE 117: one arm passes the rest on, and another makes a
        # failure that is not absence a value.
        for handler in ["|e| switch (e) { error.AccessDenied => null, else => return e }",
                        "|err| switch (err) { error.FileNotFound, error.AccessDenied => null, else => return err }",
                        "|e| switch (e) {\n        error.FileNotFound => null,\n        error.IsDir => \"\",\n        else => return e,\n    }",
                        "|e| switch (e) { error.FileNotFound => null, else => |other| blk: { log(other); break :blk null; } }",
                        "|e| if (e == error.AccessDenied) null else return e"]:
            with self.subTest(handler=handler), Tree(one(f"""\
                fn f() !?[]u8 {{
                    const raw = store.read(io, a, p, .unlimited) catch {handler};
                    return raw;
                }}
            """)) as t:
                self.assertEqual(t.lines(), [("a.zig", 3)])

    def test_an_else_whose_named_error_is_made_a_value(self):
        # metal-vmm QUEUE 117: `else |e|` was never looked at.
        for tail in ["else |e| { log(e); n = 0; }",
                     "else |e| switch (e) { error.AccessDenied => {}, else => return e }",
                     "else |err| n = if (err == error.FileNotFound) 0 else 1;"]:
            with self.subTest(tail=tail), Tree(one(f"""\
                fn f() !i64 {{
                    var n: i64 = 0;
                    if (store.read(io, a, p, .limited(64))) |body| {{
                        n = parse(body);
                    }} {tail}
                    return n;
                }}
            """)) as t:
                self.assertEqual(t.lines(), [("a.zig", 4)])


class Holds(unittest.TestCase):
    def test_a_marked_defence_on_the_line_before_says_why(self):
        with Tree(one("""\
            fn f() void {
                // absent-ok: a companion; unreadable, the page shows no author.
                const raw = store.read(io, a, p, .unlimited) catch "";
            }
        """)) as t:
            self.assertEqual(t.lines(), [])

    def test_a_named_error_that_is_passed_on(self):
        with Tree(one("""\
            fn f() !void {
                const raw = store.read(io, a, p, .unlimited) catch |e| switch (e) {
                    error.FileNotFound => "",
                    else => return e,
                };
            }
        """)) as t:
            self.assertEqual(t.lines(), [])

    def test_an_if_whose_error_is_named(self):
        with Tree(one("""\
            fn f() !i64 {
                if (store.read(io, a, p, .limited(64))) |body| {
                    return parse(body);
                } else |e| switch (e) {
                    error.FileNotFound => return 0,
                    else => return e,
                }
            }
        """)) as t:
            self.assertEqual(t.lines(), [])

    def test_each_way_of_passing_a_named_error_on(self):
        for handler in ["|e| return e", "|err| switch (err) { error.FileNotFound => null, else => return err }",
                        "|e| switch (e) { error.FileNotFound => \"\", else => e }",
                        "|e| { log(e); return e; }"]:
            with self.subTest(handler=handler), Tree(one(f"""\
                fn f() !?[]u8 {{
                    const raw = store.read(io, a, p, .unlimited) catch {handler};
                    return raw;
                }}
            """)) as t:
                self.assertEqual(t.lines(), [])

    def test_a_switch_whose_values_are_absence_alone(self):
        for handler in ["|e| switch (e) { error.FileNotFound, error.NotDir, error.NameTooLong => null, else => return e }",
                        "|e| switch (e) { error.FileNotFound => null, error.AccessDenied => return error.Forbidden, else => return e }",
                        "|e| switch (e) { error.FileNotFound => null, else => |other| return other }",
                        "|e| switch (e) { error.FileNotFound => null, else => @panic(\"no\") }",
                        "|e| if (e == error.FileNotFound) null else return e"]:
            with self.subTest(handler=handler), Tree(one(f"""\
                fn f() !?[]u8 {{
                    const raw = store.read(io, a, p, .unlimited) catch {handler};
                    return raw;
                }}
            """)) as t:
                self.assertEqual(t.lines(), [])

    def test_an_else_that_names_its_error_and_passes_it_on(self):
        for tail in ["else |e| return e;",
                     "else |e| switch (e) { error.FileNotFound => {}, else => return e }",
                     "else |e| { log(e); return e; }"]:
            with self.subTest(tail=tail), Tree(one(f"""\
                fn f() !i64 {{
                    var n: i64 = 0;
                    if (store.read(io, a, p, .limited(64))) |body| {{
                        n = parse(body);
                    }} {tail}
                    return n;
                }}
            """)) as t:
                self.assertEqual(t.lines(), [])

    def test_try_unreachable_and_panic(self):
        with Tree(one("""\
            fn f() !void {
                _ = try store.read(io, a, p, .unlimited);
                _ = store.read(io, a, p, .unlimited) catch unreachable;
                _ = store.read(io, a, p, .unlimited) catch @panic("no");
            }
        """)) as t:
            self.assertEqual(t.lines(), [])

    def test_a_write_is_not_a_read(self):
        with Tree(one("""\
            fn f() void {
                store.write(io, a, p, b, .{}) catch {};
            }
        """)) as t:
            self.assertEqual(t.lines(), [])

    def test_another_module_called_store_is_not_the_store(self):
        with Tree({"b.zig": """\
            const store = @import("chat_store.zig");
            fn f() void {
                _ = store.read(io, a, p) catch null;
            }
        """}) as t:
            self.assertEqual(t.lines(), [])

    def test_tests_and_the_store_itself(self):
        with Tree(one("""\
            test "x" {
                _ = store.read(io, a, p, .unlimited) catch "";
            }
        """) | {"store.zig": """\
            pub fn readOrEmpty() void {
                return read(io, a, p, l) catch "";
            }
        """}) as t:
            self.assertEqual(t.lines(), [])

    def test_a_name_in_a_comment_or_a_string(self):
        with Tree(one("""\
            fn f() void {
                // store.read(io) catch "" was the bug
                const s = "store.read(x) catch null";
            }
        """)) as t:
            self.assertEqual(t.lines(), [])


if __name__ == "__main__":
    unittest.main()
