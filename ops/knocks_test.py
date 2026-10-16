#!/usr/bin/env python3
"""ops/knocks' pure half on fixtures: the green one, and each alarm red."""
import base64
import gzip
import importlib.machinery
import importlib.util
import json
import os
import sys
import unittest

# ops/knocks has no .py: its bytecode would be cached by mtime and size, and
# a plant of the same size in the same second would run the old code.
sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
loader = importlib.machinery.SourceFileLoader("knocks", os.path.join(HERE, "knocks"))
spec = importlib.util.spec_from_loader("knocks", loader)
knocks = importlib.util.module_from_spec(spec)
loader.exec_module(knocks)

NOW = 1792200000.0
LIMITS = {"lynrummy": 24, "dogpark": 24, "roc": 168, "knock": 72}
ALLOW = {"203.0.113.7"}


def rec(ts, ip, method, uri, status, ua="curl/8"):
    return json.dumps({"ts": ts, "request": {"client_ip": ip, "remote_ip": ip, "method": method, "uri": uri, "headers": {"User-Agent": [ua]}}, "status": status})


def fixture(ages=None, drop=(), accepted_from="203.0.113.7"):
    ages = ages or {}
    t = {s: NOW - ages.get(s, 600) for s in LIMITS}
    secs = []
    secs.append(("/var/log/caddy/lynrummy-access.log", [rec(t["lynrummy"], "198.51.100.1", "GET", "/", 200), rec(t["lynrummy"] - 5, "198.51.100.2", "GET", "/.env", 404), rec(t["lynrummy"] - 6, "198.51.100.2", "GET", "/wp-login.php", 404)]))
    rotated = "\n".join([rec(t["dogpark"] - 9000, "192.0.2.9", "POST", "/report", 413, "zgrab/0.x"), rec(t["dogpark"] - 9001, "192.0.2.9", "GET", "/cgi-bin/x", 404)]) + "\n"
    secs.append(("/var/log/caddy/dogpark-access-2026-10-16T10-00-00.000.log.gz", base64.b64encode(gzip.compress(rotated.encode())).decode()))
    secs.append(("/var/log/caddy/dogpark-access.log", [rec(t["dogpark"], "192.0.2.10", "GET", "/", 200), rec(t["dogpark"] - 1, "192.0.2.10", "GET", "/play", 502)]))
    secs.append(("/var/log/caddy/roc-access.log", [rec(t["roc"], "198.51.100.3", "GET", "/basic/", 200)]))
    secs.append(("/var/log/caddy/knock-access.log", [rec(t["knock"], "192.0.2.50", "GET", "/.git/config", 404)]))
    text = []
    for name, body in secs:
        if any(d in name for d in drop):
            continue
        text.append("==> " + name)
        text.append(body if isinstance(body, str) else "\n".join(body))
    text.append("==> ssh")
    text += [
        "1792190000.000000 prod sshd[101]: Invalid user admin from 192.0.2.77 port 51000",
        "1792190000.100000 prod sshd[101]: Connection closed by invalid user admin 192.0.2.77 port 51000 [preauth]",
        "1792190001.000000 prod sshd[102]: Connection closed by authenticating user root 192.0.2.78 port 51001 [preauth]",
        f"1792190002.000000 prod sshd[103]: Accepted publickey for steve from {accepted_from} port 52000 ssh2: ED25519 SHA256:x",
    ]
    return "\n".join(text) + "\n"


class Knocks(unittest.TestCase):
    def test_the_green_fixture_reports_and_alarms_nothing(self):
        lines, alarms = knocks.report(fixture(), LIMITS, ALLOW, NOW)
        self.assertEqual(alarms, [])
        text = "\n".join(lines)
        self.assertIn("== dogpark: 4 requests (2xx 1, 4xx 2, 5xx 1)", text)
        self.assertIn("4xx paths: /.env 1, /wp-* 1", text)
        self.assertIn("413 192.0.2.9 POST /report zgrab/0.x", text)
        self.assertIn("502 192.0.2.10 GET /play curl/8", text)
        self.assertIn("4xx paths: /cgi-bin 1", text)
        self.assertIn("== ssh: 2 failed sessions from 2 sources", text)

    def test_other_lists_its_paths_never_only_a_count(self):
        text = fixture()
        extra = "\n".join(rec(NOW - 700 - i, "192.0.2.60", "GET", p, 404) for i, p in enumerate(["/a", "/b", "/a?x=1", "/c", "/d", "/e", "/f"]))
        text = text.replace("==> /var/log/caddy/roc-access.log\n", "==> /var/log/caddy/roc-access.log\n" + extra + "\n")
        lines, _ = knocks.report(text, LIMITS, ALLOW, NOW)
        joined = "\n".join(lines)
        self.assertIn("4xx paths: other 7", joined)
        self.assertIn("   other: /a 2, /b 1, /c 1, /d 1, /e 1 (and 1 more)", joined)

    def test_a_missing_log_alarms(self):
        _, alarms = knocks.report(fixture(drop=("roc-access",)), LIMITS, ALLOW, NOW)
        self.assertEqual(alarms, ["roc: its log is missing"])

    def test_an_empty_log_alarms(self):
        text = fixture().replace(rec(NOW - 600, "192.0.2.50", "GET", "/.git/config", 404), "")
        _, alarms = knocks.report(text, LIMITS, ALLOW, NOW)
        self.assertEqual(alarms, ["knock: its log is empty"])

    def test_a_stale_log_alarms(self):
        _, alarms = knocks.report(fixture(ages={"lynrummy": 25 * 3600}), LIMITS, ALLOW, NOW)
        self.assertEqual(len(alarms), 1)
        self.assertTrue(alarms[0].startswith("lynrummy: its newest line is 25.0 h old"))

    def test_an_accepted_login_from_elsewhere_alarms(self):
        _, alarms = knocks.report(fixture(accepted_from="192.0.2.200"), LIMITS, ALLOW, NOW)
        self.assertEqual(alarms, ["ssh: an accepted login from 192.0.2.200, not in the allowlist"])


if __name__ == "__main__":
    unittest.main()
