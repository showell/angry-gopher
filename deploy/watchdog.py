#!/usr/bin/env python3
"""watchdog — a dead-simple health monitor for the zig-server droplet.

Runs on the PROD HOST as the `steve` user, beside the server (not on the dev
box). Every minute it runs a handful of basic checks and overwrites a plain-text
status file you can read from the dev box over ssh:

    ssh steve@<host> cat watchdog-status.txt

What it checks (all thresholds are constants below — no CLI args, by design):
  - server    : the local server answers GET /version with a success JSON
                (that body carries the build's version + git commit hash)
  - process   : exactly one zig-server process is running
  - zig-uptime: how long the running binary has been up (sampled each cycle)
  - zig-memory: that process's RSS is not enormous
  - sys-memory: the box still has available RAM
  - disk      : the root filesystem still has free space
  - processes : nothing unexpected is running as `steve` (a rogue-binary smell
                test) + a list of the heavy processes for eyeballing
  - metal     : gopher-metal, on the private network, answers GET /version, and
                runs the same commit as this server (gopher-metal QUEUE item 56)
  - metal-clock: metal's clock against this server's, from both /version's
                `now_ms`, each read as its quickest of three requests with the
                round trip halved out (gopher-metal's droplet/drift.py does the
                same over an hour)

Metal's address is not in the repo: it is one line in ~/metal-url on the host
(`http://<metal's private address>`). Without that file metal is not
watched, and the `metal` line says so rather than leaving it out.

HOW A METAL FAILURE SHOWS: `[FAIL] metal  cannot reach .../version: <why>`
(metal down, or its network), and `overall: FAIL`, also appended to
watchdog.log; a `[WARN] metal` when it answers with another commit than
this server's (one of the two was deployed without the other); and
`[WARN]`/`[FAIL] metal-clock` when its clock is 2 s / 60 s off this
server's. Metal sets its clock once, from the hardware clock at boot, and
never corrects it, so a slow drift shows here first, as a WARN.

It does NOT listen on any port or open the network except to curl the local
server and, when ~/metal-url names it, metal's /version. It is intentionally robust: a bad check or a thrown exception is caught,
written to the status file, and the loop keeps going — a watchdog that dies is
worse than none.

This is the program that would have caught the first cutover's front-door gap:
/version 404 (the route wasn't ported) would have shown up as a server FAIL.

Run it (foreground, for a look):   python3 deploy/watchdog.py
Run it on the host (background):    nohup python3 watchdog.py >/dev/null 2>&1 &
(A systemd unit is the eventual home; nohup is fine for a first cut.)
"""

import datetime
import json
import os
import shutil
import time
import traceback
import urllib.request

# NYC wall-clock alongside UTC in the status header. The host (Ubuntu) ships
# tzdata, so zoneinfo handles EST/EDT correctly; guarded so a missing tz db can
# never take the watchdog down — we just fall back to UTC-only.
try:
    from zoneinfo import ZoneInfo
    NYC_TZ = ZoneInfo("America/New_York")
except Exception:
    NYC_TZ = None

# ── configuration (edit here; the program takes no arguments) ─────────────────

VERSION_URL = "http://127.0.0.1:9001/version"  # the local server liveness probe
INTERVAL_SECS = 60                             # sleep between cycles
DISK_PATH = "/"                                # filesystem to watch

ZIG_RSS_WARN_MB = 512        # warn if zig-server RSS climbs past this
SYS_AVAIL_WARN_MB = 128      # warn if available system RAM drops below this
DISK_FREE_WARN_GB = 2        # warn if free disk drops below this
DISK_USED_WARN_PCT = 85      # warn if the disk is more than this % full
HEAVY_RSS_MB = 20            # list processes using at least this much RSS

# Command names that are normal for the `steve` user on this droplet. Anything
# else running as steve is flagged for review (the rogue-binary smell test).
EXPECTED_NAMES = {
    "zig-server", "python3", "python", "bash", "sh", "dash",
    "sshd", "ssh", "scp", "rsync", "systemd", "(sd-pam)", "sftp-server",
}

# Metal: its URL, one line, e.g. http://10.0.0.5 (kept off the repo: it names a
# machine). Its clock is compared with this server's.
METAL_URL_FILE = os.path.expanduser("~/metal-url")
CLOCK_WARN_MS = 2000         # warn if metal's clock is this far off this server's
CLOCK_FAIL_MS = 60000        # fail if this far
CLOCK_TRIES = 3              # requests per host per cycle; the quickest is used

STATUS_FILE = os.path.expanduser("~/watchdog-status.txt")  # overwritten each cycle
LOG_FILE = os.path.expanduser("~/watchdog.log")            # appended on WARN/FAIL

# ── status levels ─────────────────────────────────────────────────────────────

OK, WARN, FAIL = "OK", "WARN", "FAIL"
RANK = {OK: 0, WARN: 1, FAIL: 2}


class Check:
    """One check's outcome: a level, a short name, and a human detail line."""

    def __init__(self, name, level, detail):
        self.name = name
        self.level = level
        self.detail = detail


def worst(checks):
    return max((c.level for c in checks), key=lambda lv: RANK[lv], default=OK)


# ── /proc reading (stdlib only; no psutil) ────────────────────────────────────

def read_processes():
    """Every readable process as a dict {pid, name, rss_kb, uid}. Kernel threads
    (no VmRSS) and processes that vanish mid-read are skipped."""
    procs = []
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            with open(f"/proc/{entry}/status") as f:
                name, rss_kb, uid = None, None, None
                for line in f:
                    if line.startswith("Name:"):
                        name = line.split("\t", 1)[1].strip()
                    elif line.startswith("VmRSS:"):
                        rss_kb = int(line.split()[1])
                    elif line.startswith("Uid:"):
                        uid = int(line.split()[1])  # real uid
                    if name is not None and rss_kb is not None and uid is not None:
                        break
        except (FileNotFoundError, ProcessLookupError, PermissionError, ValueError):
            continue
        if rss_kb is None:  # kernel thread / no resident memory
            continue
        procs.append({"pid": int(entry), "name": name or "?", "rss_kb": rss_kb, "uid": uid})
    return procs


def mb(kb):
    return kb / 1024.0


def proc_uptime_secs(pid):
    """Seconds the given pid has been running, derived from /proc against the
    same boot reference as /proc/uptime (so no wall-clock drift). Returns None if
    it can't be read. Sampled once per cycle, so up to INTERVAL_SECS stale — fine
    for an at-a-glance "how long has this build been up" line."""
    try:
        with open("/proc/uptime") as f:
            sys_up = float(f.read().split()[0])
        with open(f"/proc/{pid}/stat") as f:
            stat = f.read()
        # comm (field 2) is parenthesized and may contain spaces/parens, so the
        # numeric fields are taken AFTER the last ')'. starttime is field 22;
        # counting from the field right after ')' (field 3) that's index 19.
        after = stat[stat.rfind(")") + 1:].split()
        starttime_ticks = int(after[19])
        clk = os.sysconf("SC_CLK_TCK") or 100
        return sys_up - starttime_ticks / clk
    except Exception:
        return None


def human_duration(secs):
    secs = int(secs)
    d, rem = divmod(secs, 86400)
    h, rem = divmod(rem, 3600)
    m, s = divmod(rem, 60)
    parts = []
    if d:
        parts.append(f"{d}d")
    if h:
        parts.append(f"{h}h")
    if m:
        parts.append(f"{m}m")
    if not d:  # show seconds only while the uptime is still short
        parts.append(f"{s}s")
    return " ".join(parts)


# ── the checks ────────────────────────────────────────────────────────────────

def check_server():
    try:
        with urllib.request.urlopen(VERSION_URL, timeout=5) as r:
            code = r.status
            body = r.read(2000).decode("utf-8", "replace").strip()
        data = json.loads(body)
        if code == 200 and data.get("result") == "success":
            return Check("server", OK, f"/version {code} {body}")
        return Check("server", WARN, f"/version {code} unexpected body: {body}")
    except Exception as e:
        return Check("server", FAIL, f"cannot reach {VERSION_URL}: {e}")


def read_version(url):
    """(the /version JSON, its clock's offset from this machine's in ms, round
    trip in ms) from the quickest of CLOCK_TRIES requests. The offset is the
    host's `now_ms` less the request's midpoint: the round trip halved out, so
    a slow network is not read as a slow clock. Offset None when the answer
    has no now_ms (a build from before it)."""
    best = None
    for _ in range(CLOCK_TRIES):
        t0 = time.time()
        with urllib.request.urlopen(url, timeout=5) as r:
            code = r.status
            body = r.read(4000)
        t1 = time.time()
        data = json.loads(body)
        if code != 200 or data.get("result") != "success":
            raise ValueError(f"/version {code} unexpected body: {body[:200]!r}")
        rtt = (t1 - t0) * 1000
        off = data["now_ms"] - (t0 + t1) * 500 if isinstance(data.get("now_ms"), (int, float)) else None
        if best is None or rtt < best[2]:
            best = (data, off, rtt)
    return best


def metal_url():
    """Metal's base URL from METAL_URL_FILE, or None when it is not there."""
    try:
        with open(METAL_URL_FILE) as f:
            url = f.read().strip()
    except FileNotFoundError:
        return None
    return url.rstrip("/") or None


def check_metal():
    """The `metal` and `metal-clock` checks."""
    url = metal_url()
    if url is None:
        return [Check("metal", OK, f"not watched: no {METAL_URL_FILE}")]
    try:
        metal, metal_off, metal_rtt = read_version(url + "/version")
    except Exception as e:
        return [Check("metal", FAIL, f"cannot reach {url}/version: {e}"),
                Check("metal-clock", WARN, "metal did not answer")]
    try:
        prod, prod_off, _ = read_version(VERSION_URL)
    except Exception as e:
        prod, prod_off = None, None
        prod_err = e
    ours = prod.get("commit") if prod else None
    theirs = metal.get("commit")
    detail = f"/version 200, commit {theirs}, {metal_rtt:.1f} ms"
    if prod is None:
        checks = [Check("metal", OK, detail + " (this server did not answer to compare)")]
    elif theirs != ours:
        checks = [Check("metal", WARN, f"{detail}; this server runs {ours}")]
    else:
        checks = [Check("metal", OK, detail + ", the same as this server")]
    if prod is None:
        checks.append(Check("metal-clock", WARN, f"this server did not answer: {prod_err}"))
    elif metal_off is None or prod_off is None:
        checks.append(Check("metal-clock", WARN, "a /version without now_ms; the clocks cannot be compared"))
    else:
        d = metal_off - prod_off
        level = FAIL if abs(d) >= CLOCK_FAIL_MS else WARN if abs(d) >= CLOCK_WARN_MS else OK
        checks.append(Check("metal-clock", level, f"metal is {d:+.0f} ms from this server  "
                                                   f"(warn at {CLOCK_WARN_MS} ms, fail at {CLOCK_FAIL_MS} ms)"))
    return checks


def check_zig_process(zigs):
    if not zigs:
        return Check("process", FAIL, "zig-server is NOT running")
    if len(zigs) == 1:
        return Check("process", OK, f"zig-server up (pid {zigs[0]['pid']})")
    pids = ", ".join(str(p["pid"]) for p in zigs)
    return Check("process", WARN, f"{len(zigs)} zig-server processes (pids {pids}); expected exactly 1")


def check_zig_uptime(zigs):
    if not zigs:
        return Check("zig-uptime", WARN, "no zig-server process to measure")
    ups = [u for u in (proc_uptime_secs(p["pid"]) for p in zigs) if u is not None]
    if not ups:
        return Check("zig-uptime", WARN, "could not read process start time")
    return Check("zig-uptime", OK, f"up {human_duration(max(ups))}")


def check_zig_memory(zigs):
    if not zigs:
        return Check("zig-memory", WARN, "no zig-server process to measure")
    total_mb = sum(mb(p["rss_kb"]) for p in zigs)
    detail = f"RSS {total_mb:.1f} MB  (warn >= {ZIG_RSS_WARN_MB} MB)"
    return Check("zig-memory", WARN if total_mb >= ZIG_RSS_WARN_MB else OK, detail)


def check_sys_memory():
    try:
        info = {}
        with open("/proc/meminfo") as f:
            for line in f:
                k, _, rest = line.partition(":")
                info[k] = int(rest.split()[0])  # kB
        total = mb(info["MemTotal"])
        avail = mb(info.get("MemAvailable", info.get("MemFree", 0)))
    except Exception as e:
        return Check("sys-memory", WARN, f"could not read /proc/meminfo: {e}")
    detail = f"{avail:.0f} MB available of {total:.0f} MB  (warn < {SYS_AVAIL_WARN_MB} MB)"
    return Check("sys-memory", WARN if avail < SYS_AVAIL_WARN_MB else OK, detail)


def check_disk():
    try:
        total, used, free = shutil.disk_usage(DISK_PATH)
    except Exception as e:
        return Check("disk", WARN, f"could not stat {DISK_PATH}: {e}")
    free_gb = free / 1024**3
    total_gb = total / 1024**3
    used_pct = (used / total * 100) if total else 0
    level = WARN if (free_gb < DISK_FREE_WARN_GB or used_pct > DISK_USED_WARN_PCT) else OK
    detail = (f"{free_gb:.1f} GB free of {total_gb:.1f} GB, {used_pct:.0f}% used  "
              f"(warn > {DISK_USED_WARN_PCT}% or < {DISK_FREE_WARN_GB} GB)")
    return Check("disk", level, detail)


def check_unexpected(procs):
    """Flag RESIDENT processes running as the watchdog's own user (steve) whose
    command name isn't on the expected list — a cheap rogue-binary smell test.
    Gated on RSS (>= HEAVY_RSS_MB) so transient shell tools an admin runs over
    ssh (cat, head, git) don't cry wolf; a rogue daemon worth worrying about is
    long-lived and resident. The unfiltered heavy-process list below is the
    backstop for anything heavy regardless of name."""
    me = os.getuid()
    unexpected = sorted({p["name"] for p in procs
                         if p["uid"] == me
                         and p["name"] not in EXPECTED_NAMES
                         and mb(p["rss_kb"]) >= HEAVY_RSS_MB})
    if not unexpected:
        return Check("processes", OK, "no unexpected resident steve-owned processes")
    return Check("processes", WARN, "unexpected steve-owned: " + ", ".join(unexpected))


def heavy_processes(procs):
    heavy = [p for p in procs if mb(p["rss_kb"]) >= HEAVY_RSS_MB]
    heavy.sort(key=lambda p: p["rss_kb"], reverse=True)
    return heavy


# ── output ────────────────────────────────────────────────────────────────────

def now_str():
    utc = datetime.datetime.now(datetime.timezone.utc)
    s = utc.strftime("%Y-%m-%d %H:%M:%S UTC")
    if NYC_TZ is not None:
        s += utc.astimezone(NYC_TZ).strftime("  /  %Y-%m-%d %H:%M:%S %Z (New York)")
    return s


def render(checks, heavy, overall, stamp):
    lines = [f"zig-server watchdog — {stamp}",
             "=" * 60]
    for c in checks:
        lines.append(f"[{c.level:<4}] {c.name:<11} {c.detail}")
    lines.append("-" * 60)
    lines.append(f"heavy processes (RSS >= {HEAVY_RSS_MB} MB):")
    if heavy:
        for p in heavy:
            lines.append(f"  {mb(p['rss_kb']):8.1f} MB  {p['name']:<16} (pid {p['pid']}, uid {p['uid']})")
    else:
        lines.append("  (none)")
    lines.append("=" * 60)
    lines.append(f"overall: {overall}")
    return "\n".join(lines) + "\n"


def write_status(text):
    # Write to a temp file then rename, so a reader over ssh never sees a
    # half-written file.
    tmp = STATUS_FILE + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, STATUS_FILE)


def append_log(checks, overall, stamp):
    bad = "; ".join(f"{c.name}={c.level}:{c.detail}" for c in checks if c.level != OK)
    with open(LOG_FILE, "a") as f:
        f.write(f"{stamp}  overall={overall}  {bad}\n")


# ── main loop ─────────────────────────────────────────────────────────────────

def run_once():
    stamp = now_str()
    procs = read_processes()
    zigs = [p for p in procs if p["name"] == "zig-server"]
    checks = [
        check_server(),
        check_zig_process(zigs),
        check_zig_uptime(zigs),
        check_zig_memory(zigs),
        check_sys_memory(),
        check_disk(),
        check_unexpected(procs),
        *check_metal(),
    ]
    overall = worst(checks)
    write_status(render(checks, heavy_processes(procs), overall, stamp))
    if overall != OK:
        append_log(checks, overall, stamp)
    print(f"{stamp}  overall={overall}")


def main():
    while True:
        try:
            run_once()
        except Exception:
            # A watchdog must not die. Record the failure and keep going.
            stamp = now_str()
            try:
                write_status(f"zig-server watchdog — {stamp}\n\nWATCHDOG ERROR:\n{traceback.format_exc()}\n")
            except Exception:
                pass
            print(f"{stamp}  watchdog cycle error (see status file)")
        time.sleep(INTERVAL_SECS)


if __name__ == "__main__":
    main()
