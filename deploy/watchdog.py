#!/usr/bin/env python3
"""watchdog — a dead-simple health monitor for the zig-server droplet.

Runs on the PROD HOST as the `steve` user, beside the server (not on the dev
box). Every minute it runs a handful of basic checks and overwrites a plain-text
status file you can read from the dev box over ssh:

    ssh steve@<host> cat watchdog-status.txt

What it checks (all thresholds are constants below — no CLI args, by design):
  - server    : the local server answers GET /version with a success JSON
  - process   : exactly one zig-server process is running
  - zig-memory: that process's RSS is not enormous
  - sys-memory: the box still has available RAM
  - disk      : the root filesystem still has free space
  - processes : nothing unexpected is running as `steve` (a rogue-binary smell
                test) + a list of the heavy processes for eyeballing

It does NOT listen on any port or open the network except to curl the local
server. It is intentionally robust: a bad check or a thrown exception is caught,
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


def check_zig_process(zigs):
    if not zigs:
        return Check("process", FAIL, "zig-server is NOT running")
    if len(zigs) == 1:
        return Check("process", OK, f"zig-server up (pid {zigs[0]['pid']})")
    pids = ", ".join(str(p["pid"]) for p in zigs)
    return Check("process", WARN, f"{len(zigs)} zig-server processes (pids {pids}); expected exactly 1")


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
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")


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
        check_zig_memory(zigs),
        check_sys_memory(),
        check_disk(),
        check_unexpected(procs),
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
