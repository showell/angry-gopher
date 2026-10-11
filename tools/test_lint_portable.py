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
        const Io = @import("host_io").Io;
        pub fn route(io: Io) void { _ = io; }
    """,
}


def with_router(**extra):
    """router.zig importing each extra file, plus those files."""
    imports = "".join(f'const _{i} = @import("{n}");\n' for i, n in enumerate(extra))
    files = {"router.zig": 'const std = @import("std");\nconst Io = @import("host_io").Io;\n' + imports}
    files.update(extra)
    return files


class Clean(unittest.TestCase):
    def test_io_from_host_io_is_not_a_finding(self):
        with Tree(ROUTER_ONLY) as t:
            self.assertEqual(t.scan(), [])

    def test_the_real_tree_is_clean(self):
        # The lint's own subject. If this fails, run the lint for the details.
        here = os.path.dirname(os.path.abspath(__file__))
        src = os.path.join(here, "..", "zig-server", "src")
        self.assertEqual(L.scan(src, L.ROOTS), [])

    def test_the_real_partition_is_the_hosts_plus_config(self):
        # The set is DERIVED; this pins what it derives today, so a module that
        # silently falls out of (or into) reach is noticed.
        here = os.path.dirname(os.path.abspath(__file__))
        src = os.path.join(here, "..", "zig-server", "src")
        every = {f for f in os.listdir(src) if f.endswith(".zig")}
        outside = every - L.closure(src, L.ROOTS)
        self.assertEqual(outside, {
            "server.zig", "host_io_std.zig", "webbox_linux.zig", "linux_host.zig", "linux_config.zig", "bind.zig", "stress.zig", "hash_password.zig",
            "markdown_bench.zig", "markdown_hostile_probe.zig", "markdown_regression_test.zig",
            "search_bench.zig",
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

    def test_the_old_alias_to_std_is_a_finding_however_spaced(self):
        # Io comes from host_io, the one file the build swaps; an alias
        # straight to std's would be std's on every host, the machine too.
        for line in ("const Io = std.Io;", "const  Io  =  std.Io ;"):
            with self.subTest(line=line):
                with Tree(with_router(**{"a.zig": line + "\n"})) as t:
                    self.assertEqual(t.texts(), [("a.zig", "std.Io")])


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

    def test_a_file_only_the_library_reaches_is_checked(self):
        # webbox.zig is a root too: the metal port carries the library whole,
        # so a file of it the route table never imports must still port.
        files = {
            "router.zig": "\n",
            "webbox.zig": 'pub const only = @import("only.zig");\n',
            "only.zig": "const a = std.heap.page_allocator;\n",
        }
        with Tree(files) as t:
            self.assertEqual(L.closure(t.dir, L.ROOTS), {"router.zig", "webbox.zig", "only.zig"})
            self.assertEqual([name for name, _, _, _ in L.scan(t.dir, L.ROOTS)], ["only.zig"])
            self.assertEqual(t.scan(), [])  # from the route table alone it was unseen

    def test_an_import_split_over_lines_is_followed(self):
        # zig fmt keeps this form; a line-at-a-time reading never saw it.
        files = {
            "router.zig": 'const a = @import(\n    "a.zig",\n);\n',
            "a.zig": "const p = std.heap.page_allocator;\n",
        }
        with Tree(files) as t:
            self.assertEqual(L.closure(t.dir), {"router.zig", "a.zig"})
            self.assertEqual([name for name, _, _, _ in t.scan()], ["a.zig"])

    def test_a_brace_in_a_character_literal_does_not_hold_a_test_open(self):
        files = {"router.zig": (
            "test \"x\" {\n"
            "    if (c == '{') {}\n"
            "}\n"
            "const p = std.heap.page_allocator;\n"
        )}
        with Tree(files) as t:
            self.assertEqual([(n, line) for n, line, _, _ in t.scan()], [("router.zig", 4)])

    def test_a_double_slash_in_a_string_hides_nothing_after_it(self):
        files = {"router.zig": 'const u = "http://x"; const p = std.heap.page_allocator;\n'}
        with Tree(files) as t:
            self.assertEqual([n for n, _, _, _ in t.scan()], ["router.zig"])

    def test_the_library_naming_a_linux_file_is_a_finding_not_followed(self):
        # The Linux half is its own module; webbox.zig naming a file of it
        # would carry the host into every portable build.
        files = {
            "router.zig": "\n",
            "webbox.zig": 'pub const linux_host = @import("linux_host.zig");\n',
            "linux_host.zig": "var t = std.Io.Threaded.init(a, .{});\n",
        }
        with Tree(files) as t:
            self.assertEqual(L.closure(t.dir, L.ROOTS), {"router.zig", "webbox.zig"})
            self.assertEqual([(n, text) for n, _, text, _ in L.scan(t.dir, L.ROOTS)], [("webbox.zig", '@import("linux_host.zig")')])

    def test_a_portable_file_reaching_the_host_only_part_is_a_finding(self):
        files = {
            "router.zig": 'const h = @import("linux_host.zig");\n',
            "webbox.zig": "\n",
            "linux_host.zig": "var t = std.Io.Threaded.init(a, .{});\n",
        }
        with Tree(files) as t:
            found = L.scan(t.dir, L.ROOTS)
            self.assertEqual([(n, text) for n, _, text, _ in found], [("router.zig", '@import("linux_host.zig")')])

    def test_a_portable_file_importing_the_linux_module_is_a_finding(self):
        files = {
            "router.zig": 'const space = @import("webbox_linux").linux_host.freeSpaceAt("x");\n',
            "webbox.zig": "\n",
        }
        with Tree(files) as t:
            self.assertEqual([(n, text) for n, _, text, _ in L.scan(t.dir, L.ROOTS)], [("router.zig", '@import("webbox_linux")')])

    def test_the_webbox_module_is_followed_to_the_librarys_files(self):
        files = {
            "router.zig": 'const http = @import("webbox").http;\n',
            "webbox.zig": 'pub const http = @import("http.zig");\n',
            "http.zig": "const p = std.heap.page_allocator;\n",
        }
        with Tree(files) as t:
            self.assertEqual(L.closure(t.dir), {"router.zig", "webbox.zig", "http.zig"})
            self.assertEqual([n for n, _, _, _ in t.scan()], ["http.zig"])

    def test_an_application_file_importing_a_library_file_by_path_is_a_finding(self):
        # One file, one module: the application reaches the library as the
        # `webbox` module, as the metal port hands it to the kernel. The
        # library's own files import one another by path.
        files = {
            "router.zig": 'const http = @import("http.zig");\nconst w = @import("webbox.zig");\n',
            "webbox.zig": 'pub const http = @import("http.zig");\n',
            "http.zig": 'const edge = @import("edge.zig");\n',
            "edge.zig": "\n",
        }
        with Tree(files) as t:
            found = L.scan(t.dir, L.ROOTS)
            self.assertEqual([(n, text) for n, _, text, _ in found], [("router.zig", '@import("http.zig")'), ("router.zig", '@import("webbox.zig")')])
            self.assertIn('@import("webbox").http', found[0][3])

    def test_a_host_only_file_named_by_a_path_is_still_a_finding(self):
        files = {
            "router.zig": 'const h = @import("./linux_host.zig");\n',
            "webbox.zig": "\n",
            "linux_host.zig": "\n",
        }
        with Tree(files) as t:
            self.assertEqual([n for n, _, _, _ in L.scan(t.dir, L.ROOTS)], ["router.zig"])

    def test_a_missing_library_root_is_loud(self):
        with Tree({"router.zig": "\n"}) as t:
            with self.assertRaises(FileNotFoundError):
                L.closure(t.dir, L.ROOTS)

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



class StoreSeam(unittest.TestCase):
    """Io.Dir.cwd() is store.zig's alone (gopher-metal QUEUE item 54)."""

    CWD = 'fn f(io: Io) !void { try Io.Dir.cwd().writeFile(io, .{ .sub_path = "x", .data = "" }); }\n'

    def test_a_direct_call_beside_the_store_fires(self):
        with Tree(with_router(**{"a.zig": "pub " + self.CWD})) as t:
            self.assertEqual(t.texts(), [("a.zig", "Io.Dir.cwd(")])

    def test_the_store_itself_may(self):
        with Tree(with_router(**{"store.zig": "pub " + self.CWD})) as t:
            self.assertEqual(t.scan(), [])

    def test_a_module_the_route_table_does_not_reach_is_not_checked(self):
        files = dict(ROUTER_ONLY)
        files["bench.zig"] = "pub " + self.CWD
        with Tree(files) as t:
            self.assertEqual(t.scan(), [])

    def test_inside_a_test_block_it_is_allowed(self):
        body = 'test "x" {\n    try Io.Dir.cwd().writeFile(io, .{ .sub_path = "x", .data = "" });\n}\n'
        with Tree(with_router(**{"a.zig": body})) as t:
            self.assertEqual(t.scan(), [])

    def test_a_helper_only_tests_use_is_allowed_and_so_is_its_own_helper(self):
        body = textwrap.dedent("""\
            fn lower(io: Io) !void { try Io.Dir.cwd().deleteFile(io, "x"); }
            const Fixture = struct {
                io: Io,
                fn seed(self: *Fixture) !void {
                    try Io.Dir.cwd().writeFile(self.io, .{ .sub_path = "x", .data = "" });
                    try lower(self.io);
                }
            };
            test "uses the fixture" {
                var f = Fixture{ .io = io };
                try f.seed();
            }
        """)
        with Tree(with_router(**{"a.zig": body})) as t:
            self.assertEqual(t.scan(), [])

    def test_a_helper_the_code_also_uses_fires(self):
        body = textwrap.dedent("""\
            fn helper(io: Io) !void { try Io.Dir.cwd().deleteFile(io, "x"); }
            pub fn serve(io: Io) !void { try helper(io); }
            test "and a test" { try helper(io); }
        """)
        with Tree(with_router(**{"a.zig": body})) as t:
            self.assertEqual([(name, line) for name, line, _, _ in t.scan()], [("a.zig", 1)])

    def test_a_helper_nothing_uses_fires(self):
        # Nothing uses it yet: the first caller could be the route table.
        with Tree(with_router(**{"a.zig": self.CWD})) as t:
            self.assertEqual(t.texts(), [("a.zig", "Io.Dir.cwd(")])

    def test_a_pub_helper_fires_even_if_only_this_files_tests_use_it(self):
        body = "pub " + self.CWD + 'test "x" { try f(io); }\n'
        with Tree(with_router(**{"a.zig": body})) as t:
            self.assertEqual(t.texts(), [("a.zig", "Io.Dir.cwd(")])

    def test_the_exemption_is_for_tests_helpers_not_for_other_rules_reasons(self):
        # A host call in a helper only tests use is as harmless as one in a
        # test block, and is exempt the same way; in code, it still fires.
        body = textwrap.dedent("""\
            fn hostHelper() void { const a = std.heap.page_allocator; _ = a; }
            test "x" { hostHelper(); }
            pub fn serve() void { const a = std.heap.page_allocator; _ = a; }
        """)
        with Tree(with_router(**{"a.zig": body})) as t:
            self.assertEqual([line for _, line, _, _ in t.scan()], [3])


if __name__ == "__main__":
    unittest.main(verbosity=1)
