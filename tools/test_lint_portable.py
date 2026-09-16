#!/usr/bin/env python3
"""Tests for tools/lint_portable.py.

A lint that never fires is indistinguishable from a clean tree, so every rule
here is shown FIRING on a synthetic tree, and every exemption is shown HOLDING —
including the ones that only matter when the rules are subtle (a test block
whose body contains a brace in a string; a violation three imports deep; an
import cycle).

    python3 tools/test_lint_portable.py

Run by ops/check_zig, before the lint itself.
"""
import os
import sys
import tempfile
import textwrap
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lint_portable as L  # noqa: E402


class Tree:
    """A throwaway zig-server/src with the files given, as {name: source}."""

    def __init__(self, files):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name
        for name, body in files.items():
            with open(os.path.join(self.dir, name), "w", encoding="utf-8") as f:
                f.write(textwrap.dedent(body))

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.tmp.cleanup()

    def scan(self):
        return L.scan(self.dir)

    def texts(self):
        return [(name, text) for name, _, text, _ in self.scan()]


ROUTER_ONLY = {
    "router.zig": """\
        const std = @import("std");
        const Io = std.Io;
        pub fn route(io: Io) void { _ = io; }
    """,
}


def with_router(**extra):
    """router.zig importing each extra file, plus those files."""
    imports = "".join(f'const _{i} = @import("{n}");\n' for i, n in enumerate(extra))
    files = {"router.zig": 'const std = @import("std");\nconst Io = std.Io;\n' + imports}
    files.update(extra)
    return files


class Clean(unittest.TestCase):
    def test_the_alias_line_itself_is_not_a_finding(self):
        with Tree(ROUTER_ONLY) as t:
            self.assertEqual(t.scan(), [])

    def test_the_real_tree_is_clean(self):
        # The lint's own subject. If this fails, run the lint for the details.
        here = os.path.dirname(os.path.abspath(__file__))
        src = os.path.join(here, "..", "zig-server", "src")
        self.assertEqual(L.scan(src), [])

    def test_the_real_partition_is_the_hosts_plus_config(self):
        # The set is DERIVED; this pins what it derives today, so a module that
        # silently falls out of (or into) reach is noticed.
        here = os.path.dirname(os.path.abspath(__file__))
        src = os.path.join(here, "..", "zig-server", "src")
        every = {f for f in os.listdir(src) if f.endswith(".zig")}
        outside = every - L.closure(src)
        self.assertEqual(outside, {
            "server.zig", "config.zig", "stress.zig",
            "markdown_bench.zig", "markdown_hostile_probe.zig", "markdown_regression_test.zig",
        })


class Seam(unittest.TestCase):
    def test_each_ported_namespace_fires(self):
        for ns in ("Dir", "Clock", "Mutex", "Group"):
            with self.subTest(ns=ns):
                with Tree(with_router(**{"a.zig": f"const x = std.Io.{ns};\n"})) as t:
                    self.assertEqual(t.texts(), [("a.zig", f"std.Io.{ns}")])

    def test_a_bare_std_io_in_a_signature_fires(self):
        with Tree(with_router(**{"a.zig": "pub fn f(io: std.Io) void { _ = io; }\n"})) as t:
            self.assertEqual(t.texts(), [("a.zig", "std.Io")])

    def test_bare_std_io_with_whitespace_before_a_dot_is_not_bare(self):
        with Tree(with_router(**{"a.zig": "const R = std.Io .Reader;\n"})) as t:
            self.assertEqual(t.scan(), [])

    def test_reader_writer_and_limit_are_allowed(self):
        body = "const R = std.Io.Reader;\nconst W = std.Io.Writer;\nconst L = std.Io.Limit;\n"
        with Tree(with_router(**{"a.zig": body})) as t:
            self.assertEqual(t.scan(), [])

    def test_the_alias_spelled_with_extra_spaces_is_still_the_alias(self):
        with Tree(with_router(**{"a.zig": "const  Io  =  std.Io ;\n"})) as t:
            self.assertEqual(t.scan(), [])


class Host(unittest.TestCase):
    CASES = [
        ("std.Io.Threaded", "var t = std.Io.Threaded.init(a, .{});"),
        ("std.Io.net", "const net = std.Io.net;"),
        ("std.heap.page_allocator", "const a = std.heap.page_allocator;"),
        ("std.heap.c_allocator", "const a = std.heap.c_allocator;"),
        ("std.heap.raw_c_allocator", "const a = std.heap.raw_c_allocator;"),
        ("std.heap.smp_allocator", "const a = std.heap.smp_allocator;"),
        ("std.process", "fn f(env: std.process.Environ.Map) void {}"),
        ("std.posix", "const fd = std.posix.STDOUT_FILENO;"),
        ("std.Thread", "const t = std.Thread.spawn;"),
        ("std.os.", "const x = std.os.linux;"),
        ("std.c.", "const x = std.c.malloc;"),
        ("std.time.timestamp", "const t = std.time.timestamp();"),
        ("std.time.milliTimestamp", "const t = std.time.milliTimestamp();"),
        ("std.time.nanoTimestamp", "const t = std.time.nanoTimestamp();"),
        ("std.time.Timer", "var t = std.time.Timer.start();"),
        ("std.time.Instant", "const t = std.time.Instant.now();"),
        ("std.crypto.random", "std.crypto.random.bytes(&buf);"),
        ("std.fs.cwd", "const d = std.fs.cwd();"),
        ("std.fs.File", "const F = std.fs.File;"),
        ("std.debug.print", 'std.debug.print("x", .{});'),
        ("bcrypt.strHash(", "return bcrypt.strHash(pw, opts, out, io);"),
        ("pwhash.argon2.strHash(", "_ = std.crypto.pwhash.argon2.strHash(pw, opts, out, io);"),
    ]

    def test_strHashWithSalt_is_allowed(self):
        body = "return bcrypt.strHashWithSalt(pw, opts, out, salt);\n"
        with Tree(with_router(**{"a.zig": body})) as t:
            self.assertEqual(t.scan(), [])

    def test_each_host_reach_fires(self):
        for want, line in self.CASES:
            with self.subTest(want=want):
                with Tree(with_router(**{"a.zig": line + "\n"})) as t:
                    got = [text for _, text in t.texts()]
                    self.assertEqual(got, [want])

    def test_fs_path_is_allowed(self):
        with Tree(with_router(**{"a.zig": 'const p = std.fs.path.join(a, &.{"x"});\n'})) as t:
            self.assertEqual(t.scan(), [])

    def test_portable_heap_allocators_are_allowed(self):
        body = ("var fba = std.heap.FixedBufferAllocator.init(&buf);\n"
                "var arena = std.heap.ArenaAllocator.init(a);\n")
        with Tree(with_router(**{"a.zig": body})) as t:
            self.assertEqual(t.scan(), [])

    def test_std_time_constants_are_allowed(self):
        with Tree(with_router(**{"a.zig": "const s = std.time.ns_per_s;\n"})) as t:
            self.assertEqual(t.scan(), [])

    def test_a_finding_reports_its_line(self):
        body = "const ok = 1;\nconst ok2 = 2;\nconst a = std.heap.page_allocator;\n"
        with Tree(with_router(**{"a.zig": body})) as t:
            self.assertEqual([(n, line) for n, line, _, _ in t.scan()], [("a.zig", 3)])

    def test_two_violations_on_one_line_are_two_findings(self):
        body = "fn f(io: std.Io) void { _ = std.heap.page_allocator; }\n"
        with Tree(with_router(**{"a.zig": body})) as t:
            self.assertEqual(sorted(text for _, text in t.texts()),
                             ["std.Io", "std.heap.page_allocator"])


class Reach(unittest.TestCase):
    def test_an_unreachable_file_is_not_checked(self):
        files = dict(ROUTER_ONLY)
        files["host.zig"] = "const a = std.heap.page_allocator;\n"
        with Tree(files) as t:
            self.assertEqual(t.scan(), [])

    def test_a_violation_three_imports_deep_is_found(self):
        files = {
            "router.zig": 'const a = @import("a.zig");\n',
            "a.zig": 'const b = @import("b.zig");\n',
            "b.zig": 'const c = @import("c.zig");\n',
            "c.zig": "const x = std.heap.page_allocator;\n",
        }
        with Tree(files) as t:
            self.assertEqual(t.texts(), [("c.zig", "std.heap.page_allocator")])

    def test_an_import_cycle_terminates(self):
        files = {
            "router.zig": 'const a = @import("a.zig");\n',
            "a.zig": 'const b = @import("b.zig");\n',
            "b.zig": 'const a = @import("a.zig");\nconst r = @import("router.zig");\n',
        }
        with Tree(files) as t:
            self.assertEqual(L.closure(t.dir), {"router.zig", "a.zig", "b.zig"})
            self.assertEqual(t.scan(), [])

    def test_named_modules_are_not_followed(self):
        files = {"router.zig": 'const std = @import("std");\nconst o = @import("build_options");\n'}
        with Tree(files) as t:
            self.assertEqual(L.closure(t.dir), {"router.zig"})

    def test_a_dangling_import_is_not_the_lints_error(self):
        with Tree({"router.zig": 'const g = @import("gone.zig");\n'}) as t:
            self.assertEqual(L.closure(t.dir), {"router.zig"})

    def test_an_import_in_a_comment_is_not_followed(self):
        files = {
            "router.zig": '// const h = @import("host.zig");\n',
            "host.zig": "const a = std.heap.page_allocator;\n",
        }
        with Tree(files) as t:
            self.assertEqual(L.closure(t.dir), {"router.zig"})
            self.assertEqual(t.scan(), [])

    def test_a_missing_route_table_is_loud(self):
        with Tree({"server.zig": "\n"}) as t:
            with self.assertRaises(FileNotFoundError):
                L.scan(t.dir)

    def test_the_router_itself_is_checked(self):
        with Tree({"router.zig": "const a = std.heap.page_allocator;\n"}) as t:
            self.assertEqual(t.texts(), [("router.zig", "std.heap.page_allocator")])


class Exemptions(unittest.TestCase):
    def test_a_test_block_is_exempt(self):
        body = textwrap.dedent("""\
            const ok = 1;
            test "uses the host" {
                var t = std.Io.Threaded.init(std.heap.page_allocator, .{});
                defer t.deinit();
            }
        """)
        with Tree(with_router(**{"a.zig": body})) as t:
            self.assertEqual(t.scan(), [])

    def test_code_after_a_test_block_is_checked_again(self):
        body = textwrap.dedent("""\
            test "x" {
                const a = std.heap.page_allocator;
            }
            const b = std.heap.page_allocator;
        """)
        with Tree(with_router(**{"a.zig": body})) as t:
            self.assertEqual([line for _, line, _, _ in t.scan()], [4])

    def test_a_brace_in_a_string_does_not_end_a_test_block_early(self):
        body = textwrap.dedent("""\
            test "json" {
                const s = "}";
                const a = std.heap.page_allocator;
            }
        """)
        with Tree(with_router(**{"a.zig": body})) as t:
            self.assertEqual(t.scan(), [])

    def test_an_escaped_quote_does_not_confuse_the_string_tracking(self):
        body = textwrap.dedent("""\
            test "esc" {
                const s = "a \\" } b";
                const a = std.heap.page_allocator;
            }
            const c = std.heap.page_allocator;
        """)
        with Tree(with_router(**{"a.zig": body})) as t:
            self.assertEqual([line for _, line, _, _ in t.scan()], [5])

    def test_nested_braces_inside_a_test_block(self):
        body = textwrap.dedent("""\
            test "nested" {
                if (true) {
                    for (xs) |x| { _ = x; }
                }
                const a = std.heap.page_allocator;
            }
            const b = std.heap.page_allocator;
        """)
        with Tree(with_router(**{"a.zig": body})) as t:
            self.assertEqual([line for _, line, _, _ in t.scan()], [7])

    def test_a_function_named_test_something_is_not_a_test_block(self):
        body = "fn testHelper() void { _ = std.heap.page_allocator; }\n"
        with Tree(with_router(**{"a.zig": body})) as t:
            self.assertEqual(len(t.scan()), 1)

    def test_a_continuation_line_starting_with_test_is_not_a_test_block(self):
        # At depth 0 a line CAN begin with an identifier that starts "test" —
        # the second line of a wrapped expression. If that opened a "test block"
        # it would exempt everything after it until the next closing brace,
        # silently. The word boundary in the matcher is what prevents it, and
        # this is the case that proves the boundary is there.
        body = textwrap.dedent("""\
            const x = base +
                testValue;
            const a = std.heap.page_allocator;
        """)
        with Tree(with_router(**{"a.zig": body})) as t:
            self.assertEqual([line for _, line, _, _ in t.scan()], [3])

    def test_comments_are_ignored(self):
        body = ("// std.heap.page_allocator is mmap\n"
                "/// std.Io.Dir is the seam\n"
                "//! std.process is the host\n"
                "const x = 1; // std.posix, in a trailing comment\n")
        with Tree(with_router(**{"a.zig": body})) as t:
            self.assertEqual(t.scan(), [])


if __name__ == "__main__":
    unittest.main(verbosity=1)
