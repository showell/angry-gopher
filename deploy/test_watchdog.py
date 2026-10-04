#!/usr/bin/env python3
"""Tests for deploy/watchdog.py's metal checks (gopher-metal QUEUE item 56),
against real servers on this machine.

    python3 deploy/test_watchdog.py

Needs the Linux build, zig-server/zig-out/bin/zig-server (`zig build` in
zig-server/), and fails without it. Two of them play prod and metal; a
small Python server plays a metal whose clock is wrong.
"""
import http.server
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import watchdog as W  # noqa: E402

BINARY = os.path.join(HERE, "..", "zig-server", "zig-out", "bin", "zig-server")


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Server:
    """The Linux build on an empty site, on a port of its own."""

    def __init__(self):
        self.dir = tempfile.TemporaryDirectory()
        root = self.dir.name
        os.makedirs(os.path.join(root, "data"))
        os.makedirs(os.path.join(root, "auth"))
        conf = os.path.join(root, "gopher.conf")
        with open(conf, "w") as f:
            f.write("data_dir = data\nauth_dir = auth\n")
        self.port = free_port()
        self.url = f"http://127.0.0.1:{self.port}"
        env = dict(os.environ, GOPHER_CONFIG=conf, GOPHER_PORT=str(self.port), GOPHER_BIND="127.0.0.1")
        self.proc = subprocess.Popen([BINARY], cwd=root, env=env,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.time() + 20
        while time.time() < deadline:
            try:
                urllib.request.urlopen(self.url + "/version", timeout=1).read()
                return
            except OSError:
                time.sleep(0.1)
        self.stop()
        raise RuntimeError("the server did not come up")

    def stop(self):
        if self.proc.poll() is None:
            self.proc.terminate()
            self.proc.wait(10)
        self.dir.cleanup()


class Skewed:
    """A /version whose clock is `offset_ms` off, with a commit of its own and a
    settable `started_ms` (default ~100 s of uptime). Change `started_ms` to
    stand in for a restart between polls."""

    def __init__(self, offset_ms, commit="another-commit"):
        outer = self
        outer.started_ms = int(time.time() * 1000) - 100_000

        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                body = json.dumps({"result": "success", "commit": commit,
                                   "now_ms": int(time.time() * 1000 + offset_ms),
                                   "started_ms": outer.started_ms}).encode()
                self.send_response(200)
                self.send_header("content-length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *a):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def stop(self):
        self.server.shutdown()


class MetalChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not os.path.isfile(BINARY):
            raise RuntimeError(f"no {BINARY}: run `zig build` in zig-server/ first")
        cls.prod = Server()

    @classmethod
    def tearDownClass(cls):
        cls.prod.stop()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.saved = (W.VERSION_URL, W.METAL_URL_FILE, W.LINUX_SERVES_FILE, W.STATUS_FILE, W.LOG_FILE)
        W.VERSION_URL = self.prod.url + "/version"
        W.METAL_URL_FILE = os.path.join(self.tmp.name, "metal-url")
        # The marker names the Linux-serves exception; absent (the default here)
        # is the production state: metal serves.
        W.LINUX_SERVES_FILE = os.path.join(self.tmp.name, "linux-serves")
        W.STATUS_FILE = os.path.join(self.tmp.name, "watchdog-status.txt")
        W.LOG_FILE = os.path.join(self.tmp.name, "watchdog.log")
        W._metal_started_seen = None  # no restart-tracking carried in from another test

    def tearDown(self):
        W.VERSION_URL, W.METAL_URL_FILE, W.LINUX_SERVES_FILE, W.STATUS_FILE, W.LOG_FILE = self.saved
        W._metal_started_seen = None
        self.tmp.cleanup()

    def serve(self):
        """Metal serves — the production state: ensure the ~/linux-serves marker
        is absent."""
        if os.path.exists(W.LINUX_SERVES_FILE):
            os.remove(W.LINUX_SERVES_FILE)

    def linux_serves(self):
        """Linux serves — the marker is present."""
        with open(W.LINUX_SERVES_FILE, "w") as f:
            f.write("")

    def point_at(self, url):
        with open(W.METAL_URL_FILE, "w") as f:
            f.write(url + "\n")

    def levels(self, checks):
        return {c.name: c.level for c in checks}

    def test_not_configured_says_so(self):
        checks = W.check_metal()
        self.assertEqual(self.levels(checks), {"metal": W.OK})
        self.assertIn("not watched", checks[0].detail)

    def test_metal_up_with_the_same_build_and_clock(self):
        metal = Server()
        try:
            self.point_at(metal.url)
            checks = W.check_metal()
        finally:
            metal.stop()
        self.assertEqual(self.levels(checks), {"metal": W.OK, "metal-clock": W.OK, "metal-uptime": W.OK}, [c.detail for c in checks])
        self.assertIn("the same as this server", checks[0].detail)

    def test_metal_stopped_is_a_fail_that_shows_in_the_status_and_the_log(self):
        metal = Server()
        self.point_at(metal.url)
        self.assertEqual(self.levels(W.check_metal())["metal"], W.OK)
        metal.stop()
        checks = W.check_metal()
        self.assertEqual(self.levels(checks)["metal"], W.FAIL)
        self.assertIn("cannot reach", checks[0].detail)
        W.run_once()
        with open(W.STATUS_FILE) as f:
            status = f.read()
        self.assertIn("[FAIL] metal ", status)
        self.assertIn("overall: FAIL", status)
        with open(W.LOG_FILE) as f:
            self.assertIn("metal=FAIL:cannot reach", f.read())

    def test_another_commit_and_a_clock_off_warn(self):
        metal = Skewed(5000)
        try:
            self.point_at(metal.url)
            checks = W.check_metal()
        finally:
            metal.stop()
        self.assertEqual(self.levels(checks), {"metal": W.WARN, "metal-clock": W.WARN, "metal-uptime": W.OK}, [c.detail for c in checks])
        self.assertIn("this server runs", checks[0].detail)
        # About +5000: the round trips are halved out, so not far from it.
        d = float(checks[1].detail.split()[2])
        self.assertLess(abs(d - 5000), 250, checks[1].detail)

    def test_a_clock_a_minute_off_fails(self):
        metal = Skewed(-120_000)
        try:
            self.point_at(metal.url)
            checks = W.check_metal()
        finally:
            metal.stop()
        self.assertEqual(self.levels(checks)["metal-clock"], W.FAIL)

    # ── restarts must show (QUEUE item 107, fire drill 4) ────────────────────

    def test_a_metal_restart_shows_as_a_warn(self):
        metal = Skewed(0)
        try:
            self.point_at(metal.url)
            first = {c.name: c for c in W.check_metal()}
            self.assertEqual(first["metal-uptime"].level, W.OK, first["metal-uptime"].detail)
            # A restart between polls: /version stamps a new started_ms.
            metal.started_ms = int(time.time() * 1000)
            second = {c.name: c for c in W.check_metal()}
            self.assertEqual(second["metal-uptime"].level, W.WARN)
            self.assertIn("RESTARTED", second["metal-uptime"].detail)
            # It settles: no further change reads OK again.
            third = {c.name: c for c in W.check_metal()}
            self.assertEqual(third["metal-uptime"].level, W.OK)
        finally:
            metal.stop()

    # ── metal serves: this host's own server is stopped by design ────────────

    def test_serving_a_stopped_local_server_is_expected_ok(self):
        W.VERSION_URL = f"http://127.0.0.1:{free_port()}/version"  # nothing listening
        ok = W.check_server(serving=True)
        self.assertEqual(ok.level, W.OK)
        self.assertIn("stopped, as expected", ok.detail)
        # Without the serving flag, the same down server is a FAIL.
        self.assertEqual(W.check_server(serving=False).level, W.FAIL)

    def test_serving_a_running_local_server_warns(self):
        # VERSION_URL is prod (up) from setUp; a running local server while metal
        # serves is the split-brain hazard.
        warn = W.check_server(serving=True)
        self.assertEqual(warn.level, W.WARN)
        self.assertIn("split the data", warn.detail)

    def test_serving_overall_follows_metal_not_the_stopped_local_server(self):
        W.VERSION_URL = f"http://127.0.0.1:{free_port()}/version"  # local server down
        self.serve()
        metal = Server()
        self.point_at(metal.url)
        try:
            W.run_once()
            with open(W.STATUS_FILE) as f:
                status = f.read()
            # The stopped local server does not drag overall; metal is up.
            self.assertIn("stopped, as expected", status)
            self.assertNotIn("overall: FAIL", status)
            # Metal down → overall FAIL, because metal is the subject now.
            metal.stop()
            W.run_once()
            with open(W.STATUS_FILE) as f:
                status = f.read()
            self.assertIn("[FAIL] metal ", status)
            self.assertIn("overall: FAIL", status)
        finally:
            metal.stop()

    def test_the_marker_is_inverted_absent_means_metal_serves(self):
        # Absent (the default): metal serves. Present: Linux serves.
        self.assertTrue(W.metal_serving())
        self.linux_serves()
        self.assertFalse(W.metal_serving())
        self.serve()
        self.assertTrue(W.metal_serving())

    def test_linux_serves_marker_makes_the_local_server_the_subject(self):
        # With the marker present, prod (up, from setUp) is the subject again:
        # the server check is a plain OK, not the "running but metal serves" WARN.
        self.linux_serves()
        self.assertFalse(W.metal_serving())
        srv = W.check_server(serving=W.metal_serving())
        self.assertEqual(srv.level, W.OK)
        self.assertNotIn("metal serves", srv.detail)

    def test_serving_metal_clock_is_measured_against_the_host(self):
        metal = Server()
        self.serve()
        try:
            self.point_at(metal.url)
            checks = {c.name: c for c in W.check_metal(serving=True)}
        finally:
            metal.stop()
        self.assertEqual(checks["metal"].level, W.OK)
        self.assertIn("metal serves", checks["metal"].detail)
        self.assertEqual(checks["metal-clock"].level, W.OK, checks["metal-clock"].detail)
        self.assertIn("from this host", checks["metal-clock"].detail)


if __name__ == "__main__":
    unittest.main(verbosity=1)
