# Deploying Angry Gopher (Lyn Rummy)

The production host is a DigitalOcean droplet (NYC3, Ubuntu 24.04,
x86_64). Caddy fronts the **zig server** (see `SERVER.md`) for TLS and a
body cap; the server listens on `localhost:9001`. (`/admin` is gated by
the app, to uid 1 (`admin_ui.requireAdmin`), not by the proxy.)

The host runs **no zig/Go/Node/Elm toolchain** — we build locally and
ship a **single statically linked binary**: the Elm/TS bundles, the
Safari and chess WASM cores and the puzzle catalogs are baked in at
compile time (`build.zig` `@embedFile`). The site's own files —
`pages/`, `gallery/`, `downloads/` — are read from the working directory
at request time, and the deploy rsyncs them. Because the bundles are
embedded, `ops/build_elm`, `ops/build_delivery`, `ops/build_safari_wasm`
and `ops/build_chess_wasm` run *before* `zig build` (the deploy script
handles this ordering). See
`ops/deploy`.

We ship a **Debug build**, not ReleaseSafe. The server is I/O-bound (static
JS, small files, small markdown renders) with no hot compute loop, so LLVM's
optimization passes cost ~72s/deploy and buy ~nothing; Debug builds in ~7s and
carries the *full* set of runtime safety checks (a superset of ReleaseSafe's).
It's also the mode `ops/start` runs locally, so prod ships what we dogfood. Flip
`ops/deploy` back to `-Doptimize=ReleaseSafe` only if a CPU-bound path lands.

## A deploy, after the 2026-10-04 cutover

**metal serves lynrummy.com now, and prod's Linux `gopher-server` is stopped by
design** — two hosts writing two copies of the data cannot be merged
(`CUTOVER.md` in gopher-metal). So a deploy means two different things:

- **The program** ships as a new **gopher-metal image** (built and deployed in
  the gopher-metal repo). `ops/deploy` does NOT touch the program on prod.
- **The content trees** (`pages/`, `gallery/`) **and the watchdog** still ship
  to the prod host, which is now the aux box the watchdog runs on.

`ops/deploy` reads the marker file `~/metal-serves` on the prod host (the
cutover creates it): while it is there, the script ships content + the watchdog
and **refuses to build or start the Linux server**. `ops/test_deploy` pins that
refusal.

```
ops/deploy        # metal serving: ships content + watchdog, never starts Linux
```

## Repeat deploys (pre-cutover / a fallback to Linux only)

With `~/metal-serves` absent — a box before the cutover, or a deliberate
fallback to the Linux server — `ops/deploy` is the full deploy as before:

```
ops/deploy
```

Builds locally, rsyncs to the droplet (target in `deploy/deploy.conf`),
restarts the `gopher-server` systemd service.

## One-time host setup

Run once on a fresh droplet (the `steve` user has passwordless sudo;
the SSH key was added at droplet creation).

1. **Directories**

   ```
   ssh steve@<IP> 'mkdir -p ~/angry-gopher ~/AngryGopher/prod'
   ```

2. **Config** — copy the local `gopher.conf` and repoint `data_dir`.
   The config (`data_dir`, `auth_dir`) lives only on the host, never in
   git. The port is not in it: `GOPHER_PORT`, default 9001.

   ```
   scp ~/AngryGopher/gopher.conf steve@<IP>:~/AngryGopher/gopher.conf
   ssh steve@<IP> "sed -i 's|^data_dir.*|data_dir = /home/steve/AngryGopher/prod|' ~/AngryGopher/gopher.conf"
   ```

3. **systemd unit**

   ```
   scp deploy/gopher-server.service steve@<IP>:/tmp/
   ssh steve@<IP> 'sudo mv /tmp/gopher-server.service /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable gopher-server'
   ```

4. **First deploy** (puts the binary + files in place, starts the service)

   ```
   ops/deploy
   ```

5. **Caddy**

   ```
   ssh steve@<IP> 'sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl && \
     curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg && \
     curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt | sudo tee /etc/apt/sources.list.d/caddy-stable.list && \
     sudo apt-get update && sudo apt-get install -y caddy'
   ```

   Then install the Caddyfile:

   ```
   scp deploy/Caddyfile steve@<IP>:/tmp/
   ssh steve@<IP> 'sudo mv /tmp/Caddyfile /etc/caddy/Caddyfile && sudo systemctl reload caddy'
   ```

## Watchdog

`deploy/watchdog.py` is a dead-simple, stdlib-only health monitor that runs
ON the host as `steve` (not on the dev box). Every minute it checks: the
local server answers `GET /version`, exactly one `zig-server` process is up
and not hogging memory, the box has free RAM and disk, and nothing
unexpected is running as `steve`. It overwrites a plain-text snapshot you
read over ssh:

```
ssh steve@<IP> cat watchdog-status.txt      # latest snapshot
ssh steve@<IP> cat watchdog.log             # appended history of WARN/FAIL cycles
```

The snapshot header carries both UTC and New York wall-clock; the `server`
line includes the build's git commit hash (baked in via `ops/deploy`'s
`-Dcommit`), and a `zig-uptime` line shows how long the running binary has
been up.

It also watches gopher-metal, when `~/metal-url` on the host names it (one
line, `http://<metal's private address>`; the address stays off the repo):
`metal` FAILs when metal's `/version` does not answer and WARNs when metal
runs another commit than this server, and `metal-clock` WARNs at 2 s and
FAILs at 60 s between the two clocks. Without the file the `metal` line
says "not watched". `python3 deploy/test_watchdog.py` tests those checks
against two local servers, one of them stopped (needs `zig build` first).

It takes no arguments (thresholds are constants at the top of the file) and
opens no network except to curl the local server and metal's `/version`. ONE-TIME install as a
systemd service (auto-start on boot, auto-restart on crash — survives a
droplet reboot, same as `gopher-server`):

```
scp deploy/watchdog.py steve@<IP>:~/watchdog.py
scp deploy/watchdog.service steve@<IP>:/tmp/
ssh steve@<IP> 'sudo mv /tmp/watchdog.service /etc/systemd/system/ && \
  sudo systemctl daemon-reload && sudo systemctl enable --now watchdog'
```

After that, `ops/deploy` ships the current `watchdog.py` and restarts the
service on every deploy (best-effort), so the host copy never drifts from the
repo — no manual update step. To bounce it by hand anyway:
`ssh steve@<IP> 'sudo systemctl restart watchdog'`.

## Hardening (applied 2026-05-21)

- **TLS:** live on `https://lynrummy.com` (Let's Encrypt via Caddy,
  auto-renew); HTTP→HTTPS redirect; HSTS.
- **Security headers** (Caddyfile): HSTS, `X-Content-Type-Options`,
  `Referrer-Policy`, `X-Frame-Options`.
- **SSH:** key-only (password auth off via cloud-init drop-ins);
  root login disabled (`/etc/ssh/sshd_config.d/99-hardening.conf` →
  `PermitRootLogin no`). Log in as `steve`.
- **Auto updates:** `unattended-upgrades` enabled (DO image default).
- **Firewall:** ufw allows 22/80/443 only.
- **Backups:** `ops/backup` pulls a timestamped `data_dir` tarball to
  `~/AngryGopher/backups` on the dev box. Also worth enabling
  DigitalOcean weekly droplet backups in the control panel for
  whole-droplet recovery.
- **Account store (`~/Auth`):** the shared account data — `name`, `password`,
  `api-key`, and `next-id.txt` — lives under `~/Auth` (config `auth_dir`,
  default `~/Auth`), deliberately OUTSIDE `data_dir`. So it is **not** in the
  `ops/backup` tarball (back it up separately — it holds credentials), and a
  sibling app can share accounts without reaching into `~/AngryGopher`.
  gopher-private per-user data (last-seen, upload-bytes) stays under
  `{data_dir}/users/<id>/`. A fresh host starts already-split; the prod host
  was migrated 2026-05-29 (the one-shot migration tool has since been removed —
  pull it from git history if another existing host ever needs it).

### Deferred to the guests phase

A dedicated least-privilege service user; Caddy rate-limiting (`xcaddy`
+ `caddy-ratelimit`).
