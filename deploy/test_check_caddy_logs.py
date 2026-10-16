#!/usr/bin/env python3
"""deploy/check_caddy_logs.py on fixtures, and on deploy/Caddyfile itself."""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_caddy_logs as lint  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))

GOOD = """{
	default_sni 1.2.3.4
}
(access_log) {
	log {
		output file /var/log/caddy/{args[0]}-access.log
	}
}
a.example {
	import access_log a
	header {
		X-Thing "a { quoted brace"
	}
	reverse_proxy 10.0.0.1:80 # a } in a comment
}
http://1.2.3.4 {
	import access_log knock
	respond 404
}
"""


class Lint(unittest.TestCase):
    def test_every_block_logs(self):
        blocks = lint.site_blocks(GOOD)
        self.assertEqual([(h, logs) for _, h, logs in blocks], [("a.example", True), ("http://1.2.3.4", True)])

    def test_a_block_without_the_import_is_named(self):
        text = GOOD.replace("\timport access_log knock\n", "")
        bad = [(n, h) for n, h, logs in lint.site_blocks(text) if not logs]
        self.assertEqual(bad, [(16, "http://1.2.3.4")])

    def test_an_import_nested_deeper_does_not_count(self):
        text = "b.example {\n\thandle {\n\t\timport access_log b\n\t}\n}\n"
        self.assertEqual([logs for _, _, logs in lint.site_blocks(text)], [False])

    def test_the_repos_caddyfile_passes_and_fails_with_an_import_gone(self):
        path = os.path.join(HERE, "Caddyfile")
        self.assertEqual(lint.missing(path), [])
        with open(path) as f:
            text = f.read()
        self.assertIn("\timport access_log lynrummy\n", text)
        with tempfile.NamedTemporaryFile("w", suffix=".caddy", delete=False) as t:
            t.write(text.replace("\timport access_log lynrummy\n", "", 1))
        try:
            self.assertEqual(len(lint.missing(t.name)), 1)
            self.assertEqual(lint.main([t.name]), 1)
        finally:
            os.unlink(t.name)


if __name__ == "__main__":
    unittest.main()
