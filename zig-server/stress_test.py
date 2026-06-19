#!/usr/bin/env python3
"""Adversarial stress + leak harness for the zig server (lynrummy.com port).

Steve's pre-deploy concern (#General > zig-port, 2026-06-19) is MEMORY: crashes
and leaks, NOT credential security (covered earlier). So this harness has two
jobs:

  1. CRASH HUNTING — throw malformed / hostile traffic (raw sockets, so we can
     send bytes curl would refuse) at every endpoint, probing liveness after
     each batch. The server is a Debug build: any memory-safety violation is a
     loud panic = process death, which `alive()` catches immediately and pins to
     the payload that did it.

  2. LEAK HUNTING — hammer the server (sequential, SSE open/abrupt-close, and a
     concurrent flood) while sampling its RSS from /proc. The per-connection
     arena frees request memory on close, so RSS should settle near baseline; a
     monotone climb across phases is the leak signal.

  3. COMPLEXITY / REJECT — a CPU-DoS is neither a crash nor a leak: a single
     hostile message can be O(n²) in the markdown parser and peg a core for
     tens of seconds (found 2026-06-19: "[[[[…", "[]([]([…", "a_b_a_b…"). This
     job times render at growing input sizes and flags any super-linear blowup,
     and checks that over-formatted input is rejected as malformed while normal
     prose and fenced code still render. Defends both the linear-scanner fix and
     the 256-markup-token reject cap from regressing.

Markdown-content fuzzing routes through POST /chat/docs/render (renders, never
writes), so we exercise the hot markdown/parse paths without polluting any
transcript. Run with the server already up on :9001.

    python3 zig-server/stress_test.py
"""

import os, socket, ssl, sys, time, threading, subprocess

HOST, PORT = "127.0.0.1", 9001
KEY = open(os.path.expanduser("~/Auth/1/api-key")).read().strip()
AUTH = f"Authorization: Bearer {KEY}"

# ── low-level raw HTTP (so we can send bytes curl normalizes away) ────────────

def raw(payload: bytes, timeout=4.0, read=512):
    """Send raw bytes; return (status_int|None, raw_response_head). None status
    means no parseable response (connection died / timed out)."""
    try:
        s = socket.create_connection((HOST, PORT), timeout=timeout)
        s.settimeout(timeout)
        s.sendall(payload)
        data = s.recv(read)
        s.close()
        if data.startswith(b"HTTP/"):
            try:
                return int(data.split()[1]), data
            except Exception:
                return -1, data
        return None, data
    except Exception as e:
        return None, str(e).encode()

def req(method, path, headers=None, body=b"", timeout=4.0):
    """Build a well-framed request (correct Content-Length) and send it raw."""
    h = [f"{method} {path} HTTP/1.1", f"Host: {HOST}", "Connection: close"]
    if headers:
        h += headers
    if body:
        h.append(f"Content-Length: {len(body)}")
    blob = ("\r\n".join(h) + "\r\n\r\n").encode() + body
    return raw(blob, timeout=timeout)

PID = int(subprocess.check_output(["pgrep", "-x", "zig-server"]).split()[0])

def rss_kb():
    try:
        for line in open(f"/proc/{PID}/status"):
            if line.startswith("VmRSS:"):
                return int(line.split()[1])
    except OSError:
        return -1  # process gone (crashed) — caller sees the -1
    return -1

def alive():
    """Liveness probe: a normal public GET must return 200."""
    st, _ = req("GET", "/learn")
    return st == 200

# ── crash battery ─────────────────────────────────────────────────────────────

deaths = []        # (category, label) that left the server unresponsive
regressions = []   # (category, label) non-fatal failures (slow render, bad reject)

def check(category, label):
    if not alive():
        # one retry — the probe itself may have raced a transient
        time.sleep(0.3)
        if not alive():
            deaths.append((category, label))
            print(f"  ☠️  SERVER DOWN after [{category}] {label}")
            return False
    return True

def batch(category, cases):
    """cases: list of (label, send-thunk). Run each, probe liveness after."""
    print(f"[{category}] {len(cases)} cases")
    for label, thunk in cases:
        try:
            thunk()
        except Exception:
            pass  # a client-side socket error is fine; we care if the SERVER died
        if not check(category, label):
            return  # stop this category once the server is down

LONG = "A" * 9000
HUGE = b"x" * (200 * 1024)

def malformed_lines():
    return [
        ("9000-char path",        lambda: raw(f"GET /{LONG} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".encode())),
        ("no path",               lambda: raw(b"GET  HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")),
        ("bogus method",          lambda: raw(b"ZZZZZZ /learn HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")),
        ("garbage line",          lambda: raw(b"\x00\x01\x02 not http\r\n\r\n")),
        ("bare CRLF flood",       lambda: raw(b"\r\n" * 500)),
        ("no HTTP version",       lambda: raw(b"GET /learn\r\n\r\n")),
        ("absurd version",        lambda: raw(b"GET /learn HTTP/9.99\r\nHost: x\r\nConnection: close\r\n\r\n")),
        ("slashes",               lambda: req("GET", "//////////")),
        ("traversal enc",         lambda: req("GET", "/chat/c/1_2/general1/uploads/..%2f..%2f..%2f..%2fetc%2fpasswd", [AUTH])),
        ("traversal raw",         lambda: req("GET", "/chat/c/1_2/general1/uploads/../../../../etc/passwd", [AUTH])),
        ("nul in path",           lambda: req("GET", "/chat/c/1_2/gen%00eral1/raw", [AUTH])),
        ("invalid utf8 path",     lambda: req("GET", "/chat/c/1_2/%ff%fe%fd", [AUTH])),
        ("empty conv",            lambda: req("GET", "/chat/c/_", [AUTH])),
        ("empty channel",         lambda: req("GET", "/channel//", [AUTH])),
        ("long conv",             lambda: req("GET", "/chat/c/" + "A" * 5000, [AUTH])),
        ("msg ref underscores",   lambda: req("GET", "/chat/msg/" + "_" * 2000, [AUTH])),
        ("msg ref empty-ish",     lambda: req("GET", "/chat/msg/____", [AUTH])),
        ("admin huge user",       lambda: req("GET", "/admin/delete?user=" + "9" * 5000, [AUTH])),
    ]

def malformed_query():
    return [
        ("since overflow",  lambda: req("GET", "/chat/c/1_2/general1/stream?since=" + "9" * 40, [AUTH], timeout=2)),
        ("since negative",  lambda: req("GET", "/chat/c/1_2/general1/stream?since=-5", [AUTH], timeout=2)),
        ("since nan",       lambda: req("GET", "/chat/c/1_2/general1/stream?since=abc", [AUTH], timeout=2)),
        ("huge query",      lambda: req("GET", "/chat/recent?x=" + "9" * 8000, [AUTH])),
        ("repeated params", lambda: req("GET", "/settings?" + "&".join(["show=1"] * 2000), [AUTH])),
        ("admin flags",     lambda: req("GET", "/admin?deleted=" + "Z" * 4000, [AUTH])),
    ]

def malformed_headers():
    return [
        ("1000 headers",    lambda: req("GET", "/learn", [f"X-{i}: v" for i in range(1000)])),
        ("100KB header",    lambda: req("GET", "/learn", ["X-Big: " + "v" * (100 * 1024)])),
        ("huge cookie",     lambda: req("GET", "/chat", ["Cookie: gopher_auth=" + "z" * 60000])),
        ("bearer no token", lambda: req("GET", "/chat", ["Authorization: Bearer"])),
        ("bearer huge",     lambda: req("GET", "/chat", ["Authorization: Bearer " + "x" * 40000])),
        ("LEI overflow",    lambda: req("GET", "/chat/c/1_2/general1/stream", [AUTH, "Last-Event-ID: " + "9" * 50], timeout=2)),
        ("LEI garbage",     lambda: req("GET", "/chat/c/1_2/general1/stream", [AUTH, "Last-Event-ID: ../../x"], timeout=2)),
        ("CL lie short",    lambda: raw(b"POST /chat/docs/render HTTP/1.1\r\nHost: x\r\n" + AUTH.encode() + b"\r\nContent-Length: 1000000\r\nConnection: close\r\n\r\nbody=hi", timeout=2)),
        ("CL negative",     lambda: req("POST", "/chat/docs/render", [AUTH, "Content-Length: -1"], b"body=x")),
        ("CL overflow",     lambda: raw(b"POST /chat/docs/render HTTP/1.1\r\nHost: x\r\n" + AUTH.encode() + b"\r\nContent-Length: 99999999999999999999\r\nConnection: close\r\n\r\nbody=x", timeout=2)),
    ]

def malformed_forms():
    R = "/chat/docs/render"
    bad = [
        ("trailing pct",   b"body=%"),
        ("bad pct hex",    b"body=%G0%ZZ"),
        ("half pct",       b"body=%0"),
        ("pct flood",      b"body=" + b"%" * 5000),
        ("plus/ff",        b"body=+++%ff%fe"),
        ("null bytes",     b"body=a\x00b\x00c"),
        ("amp flood",      b"&" * 8000),
        ("no eq",          b"bodyyyyy"),
        ("huge field",     b"body=" + b"Z" * (300 * 1024)),  # > max_doc_bytes → 413
    ]
    return [(lbl, (lambda b=b: req("POST", R, [AUTH], b))) for lbl, b in bad]

def markdown_fuzz():
    """Pathological markdown through /chat/docs/render — exercises the renderer,
    MSG_ linkifier, image-tag + code-fence extractors. No write."""
    R = "/chat/docs/render"
    payloads = [
        ("deep blockquote",   b"body=" + b"%3E+" * 20000),                       # "> " *20000
        ("deep brackets",     b"body=" + b"%5B" * 20000),                        # "[" *20000
        ("nested images",     b"body=" + b"!%5B" * 8000 + b"x"),                 # "![" *8000
        ("unbalanced fence",  b"body=" + b"%60%60%60lang%0A" + b"code%0A" * 5000),  # ```lang\n code...
        ("tilde fence soup",  b"body=" + b"~~~go%0Ax%0A~~~+quote%0A" * 3000),
        ("giant heading",     b"body=" + b"%23" * 50000),                        # "#" *50000
        ("msg ref spam",      b"body=" + b"MSG_general1_1+" * 8000),
        ("img tag spam",      b"body=" + b"%3Cimg+src%3Dx%3E" * 8000),           # "<img src=x>" *8000
        ("mixed huge",        b"body=" + (b"%23+h%0A%3E+q%0A%60%60%60c%0Ax%0A%60%60%60%0A!%5Ba%5D(b)%0A" * 2000)),
        ("lone backslashes",  b"body=" + b"%5C" * 20000),
    ]
    return [(lbl, (lambda b=b: req("POST", R, [AUTH], b, timeout=8))) for lbl, b in payloads]

def upload_fuzz():
    """Adversarial multipart against the upload parser (the hand-rolled one that
    already bit us once with invalidateStrings). Targets a scratch topic; any
    bytes that DO get stored are cleaned by the caller."""
    U = "/chat/c/1_3/StressScratch/upload"
    def mp(boundary, body):
        return req("POST", U, [AUTH, f"Content-Type: multipart/form-data; boundary={boundary}"], body, timeout=6)
    cases = [
        ("no boundary",       lambda: req("POST", U, [AUTH, "Content-Type: multipart/form-data"], b"junk")),
        ("boundary mismatch", lambda: mp("AAAA", b"--BBBB\r\nContent-Disposition: form-data; name=\"file\"\r\n\r\ndata\r\n--BBBB--")),
        ("empty boundary",    lambda: mp("", b"----\r\n\r\nx")),
        ("truncated part",    lambda: mp("X", b"--X\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.png\"\r\n\r\n\x89PNG")),
        ("no file field",     lambda: mp("X", b"--X\r\nContent-Disposition: form-data; name=\"other\"\r\n\r\nv\r\n--X--")),
        ("huge filename",     lambda: mp("X", b"--X\r\nContent-Disposition: form-data; name=\"file\"; filename=\"" + b"A" * 20000 + b".png\"\r\n\r\n\x89PNG\r\n\x1a\n\r\n--X--")),
        ("filename newlines",  lambda: mp("X", b"--X\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a\r\nb.png\"\r\n\r\ndata\r\n--X--")),
        ("bogus magic",       lambda: mp("X", b"--X\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.png\"\r\n\r\nNOTANIMAGE\r\n--X--")),
        ("1-byte image",      lambda: mp("X", b"--X\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.png\"\r\n\r\n\x89\r\n--X--")),
        ("nested boundaries", lambda: mp("X", b"--X\r\n--X\r\n--X\r\nContent-Disposition: form-data; name=\"file\"\r\n\r\n--X--")),
        ("oversize claim",    lambda: mp("X", b"--X\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.png\"\r\n\r\n" + b"\x89PNG\r\n\x1a\n" + b"P" * (11 << 20) + b"\r\n--X--", )),
    ]
    return cases

# ── complexity / reject phase ──────────────────────────────────────────────────

def post_render(md: bytes, timeout=30.0):
    """POST raw markdown to /chat/docs/render, full-read the response. Returns
    (elapsed_s, status|None, body_bytes). The md goes in a urlencoded `body=`
    field; our probe payloads use only form-safe bytes ([ ] _ ( ) a b ` # space)."""
    payload = b"body=" + md
    blob = (f"POST /chat/docs/render HTTP/1.1\r\nHost: {HOST}\r\n{AUTH}\r\n"
            f"Content-Type: application/x-www-form-urlencoded\r\n"
            f"Content-Length: {len(payload)}\r\nConnection: close\r\n\r\n").encode() + payload
    t0 = time.time()
    try:
        s = socket.create_connection((HOST, PORT), timeout=timeout)
        s.settimeout(timeout)
        s.sendall(blob)
        chunks = []
        while True:
            d = s.recv(65536)
            if not d:
                break
            chunks.append(d)
        s.close()
    except Exception as e:
        return time.time() - t0, None, str(e).encode()
    resp = b"".join(chunks)
    status = int(resp.split()[1]) if resp.startswith(b"HTTP/") else None
    sep = resp.find(b"\r\n\r\n")
    return time.time() - t0, status, (resp[sep + 4:] if sep >= 0 else b"")

def complexity_and_reject():
    """Time render at growing sizes (catch super-linear CPU blowup) and verify
    over-formatted input is rejected while normal/code input renders."""
    print("[complexity] render must stay sub-linear-ish; floods must be refused")
    MALFORMED = b"malformed markdown"
    # Vectors that were O(n²) before the monotonic-cursor fix. With the reject
    # cap they're refused in O(n); if BOTH layers regress, n=80000 reverts to
    # 5–35s and trips the threshold below.
    vectors = {
        "unclosed [":    lambda n: b"[" * n,
        "[]( no )":      lambda n: b"[](" * (n // 3),
        "a_b_ emphasis": lambda n: b"a_b_" * (n // 4),
    }
    sizes = [20000, 40000, 80000]
    for name, mk in vectors.items():
        ts = [post_render(mk(n))[0] for n in sizes]
        flag = "SUPER-LINEAR!" if ts[-1] > 1.0 else "ok"
        print(f"    {name:16} n={sizes[0]}→{sizes[-1]}: {ts[0]:.3f}s → {ts[-1]:.3f}s  [{flag}]")
        if ts[-1] > 1.0:
            regressions.append(("complexity", f"{name}: {ts[-1]:.1f}s at n={sizes[-1]} (super-linear)"))
    # Reject correctness: floods → malformed; ordinary prose + fenced code → render.
    checks = [
        ("flood [ → malformed",   b"[" * 300,                              True),
        ("flood _ → malformed",   b"a" + b"_b" * 300,                      True),
        ("normal prose renders",  b"# Hi *there* [x](/y) `c` e@host.com",  False),
        ("fenced code exempt",    b"```\n" + b"a_b_c_d_e_f " * 40 + b"\n```", False),
    ]
    for label, md, want_bad in checks:
        _, st, body = post_render(md)
        got_bad = MALFORMED in body
        ok = st == 200 and got_bad == want_bad
        print(f"    {label:22} status={st} malformed={got_bad}  [{'PASS' if ok else 'FAIL'}]")
        if not ok:
            regressions.append(("complexity", f"{label}: status={st} malformed={got_bad}, wanted {want_bad}"))

# ── leak phase ────────────────────────────────────────────────────────────────

def hammer_sequential(n):
    paths = ["/learn", "/chat", "/chat/recent", "/chat/images", "/chat/code",
             "/chat/conversations", "/settings", "/admin", "/chat/c/1_2/general1",
             "/channel/General/ChitChat", "/chat/docs", "/driving"]
    for i in range(n):
        req("GET", paths[i % len(paths)], [AUTH])

def sse_churn(n):
    """Open an SSE stream and abruptly RST-close it — stresses subscriber
    open/close (a leaked subscriber would grow RSS linearly)."""
    for _ in range(n):
        try:
            s = socket.create_connection((HOST, PORT), timeout=3)
            s.sendall((f"GET /chat/c/1_2/general1/stream HTTP/1.1\r\nHost: {HOST}\r\n{AUTH}\r\nConnection: close\r\n\r\n").encode())
            s.recv(64)  # let the server register the subscriber + send preamble
            # Abrupt RST (SO_LINGER 0) rather than a clean close.
            s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, (1).to_bytes(2, "little") + (0).to_bytes(6, "little"))
            s.close()
        except Exception:
            pass

def flood(total, threads):
    paths = ["/learn", "/chat/recent", "/chat/c/1_2/general1", "/admin", "/settings"]
    per = total // threads
    def worker(tid):
        for i in range(per):
            req("GET", paths[(tid + i) % len(paths)], [AUTH], timeout=6)
    ts = [threading.Thread(target=worker, args=(t,)) for t in range(threads)]
    for t in ts: t.start()
    for t in ts: t.join()

def settle_rss(label):
    time.sleep(1.0)
    print(f"    RSS {label}: {rss_kb()} kB")
    return rss_kb()

# ── run ────────────────────────────────────────────────────────────────────────

def main():
    if not alive():
        print("server not responding on :9001 — start it first"); sys.exit(2)
    print(f"server pid={PID}  baseline RSS={rss_kb()} kB\n")

    print("══ CRASH HUNTING ══")
    batch("malformed-request",  malformed_lines())
    batch("malformed-query",    malformed_query())
    batch("malformed-headers",  malformed_headers())
    batch("malformed-forms",    malformed_forms())
    batch("markdown-fuzz",      markdown_fuzz())
    batch("upload-fuzz",        upload_fuzz())

    print("\n══ COMPLEXITY / REJECT ══")
    complexity_and_reject()

    print("\n══ LEAK HUNTING ══")
    base = settle_rss("baseline")
    print("  5000 sequential mixed GETs…");      hammer_sequential(5000); r1 = settle_rss("after sequential")
    print("  1500 SSE open/abrupt-close…");      sse_churn(1500);          r2 = settle_rss("after SSE churn")
    print("  6000 concurrent GETs (40 threads)…"); flood(6000, 40);        r3 = settle_rss("after flood")
    print("  cooldown…");                         time.sleep(3);            r4 = settle_rss("final")

    print("\n══ SUMMARY ══")
    print(f"  RSS: base {base} → seq {r1} → sse {r2} → flood {r3} → final {r4} kB"
          f"  (net +{r4 - base} kB)")
    if deaths:
        print(f"  ❌ {len(deaths)} CRASH(es):")
        for c, l in deaths:
            print(f"       [{c}] {l}")
    else:
        print("  ✅ no crashes — server survived every adversarial case")
    if regressions:
        print(f"  ❌ {len(regressions)} REGRESSION(s):")
        for c, l in regressions:
            print(f"       [{c}] {l}")
    else:
        print("  ✅ no complexity/reject regressions")
    # Heuristic leak flag: sustained growth well past arena/page-cache slack.
    if r4 - base > 20000:
        print(f"  ⚠️  RSS grew {r4 - base} kB and didn't settle — investigate for a leak")
    else:
        print(f"  ✅ RSS settled (net +{r4 - base} kB ≈ allocator/page slack, not a leak)")
    print(f"  server still alive: {alive()}")
    sys.exit(1 if (deaths or regressions) else 0)

if __name__ == "__main__":
    main()
