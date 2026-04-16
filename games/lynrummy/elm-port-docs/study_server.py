#!/usr/bin/env python3
"""Minimal HTTP sink for LynRummy study trial data.

Listens on localhost:8811. Accepts POST /trial with a JSON body and
appends one JSON line per POST to a timestamped log file under
study_logs/. CORS open so the elm-lynrummy page on :8810 can post.
"""

import http.server
import json
import os
import sys
from datetime import datetime

LOG_DIR = os.path.expanduser("~/showell_repos/elm-lynrummy/study_logs")
os.makedirs(LOG_DIR, exist_ok=True)
LOG_FILE = os.path.join(
    LOG_DIR,
    f"study_{datetime.now().strftime('%Y%m%d_%H%M%S')}.jsonl",
)

print(f"[study-sink] writing to {LOG_FILE}", flush=True)


class Handler(http.server.BaseHTTPRequestHandler):
    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8")
        try:
            parsed = json.loads(body)
            line = json.dumps(parsed, separators=(",", ":"))
        except json.JSONDecodeError:
            line = body.strip()
        with open(LOG_FILE, "a") as f:
            f.write(line + "\n")
        print(f"[study-sink] trial {parsed.get('trial', '?')}", flush=True)
        self.send_response(200)
        self._cors()
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"ok":true}')

    def log_message(self, *a, **k):
        pass  # silence default access logging; we print our own line


def main():
    srv = http.server.HTTPServer(("localhost", 8811), Handler)
    print("[study-sink] listening on http://localhost:8811/trial", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
