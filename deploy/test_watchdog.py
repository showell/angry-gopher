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
    """A /version whose clock is `offset_ms` off, with a commit of its own."""

    def __init__(self, offset_ms, commit="another-commit"):
        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                body = json.dumps({"result": "success", "commit": commit,
                                   "now_ms": int(time.time() * 1000 + offset_ms)}).encode()
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
        self.saved = (W.VERSION_URL, W.METAL_URL_FILE, W.STATUS_FILE, W.LOG_FILE)
        W.VERSION_URL = self.prod.url + "/version"
        W.METAL_URL_FILE = os.path.join(self.tmp.name, "metal-url")
        W.STATUS_FILE = os.path.join(self.tmp.name, "watchdog-status.txt")
        W.LOG_FILE = os.path.join(self.tmp.name, "watchdog.log")

    def tearDown(self):
        W.VERSION_URL, W.METAL_URL_FILE, W.STATUS_FILE, W.LOG_FILE = self.saved
        self.tmp.cleanup()

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
        self.assertEqual(self.levels(checks), {"metal": W.OK, "metal-clock": W.OK}, [c.detail for c in checks])
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
        self.assertEqual(self.levels(checks), {"metal": W.WARN, "metal-clock": W.WARN}, [c.detail for c in checks])
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


if __name__ == "__main__":
    unittest.main(verbosity=1)
