# Deploying Angry Gopher (Lyn Rummy)

> **lynrummy.com is served by zig-metal-unikernel** (the top-level README,
> "Where it runs"); releasing it is zig-metal-unikernel's
> [DEPLOY.md](https://github.com/showell/zig-metal-unikernel/blob/master/DEPLOY.md). This
> droplet runs Caddy, which proxies to metal, and the watchdog; its zig
> server is stopped. `ops/deploy` fails closed (below): while metal serves,
> it refreshes the watchdog and stops. The Linux-host sections are the
> fallback.

The prod host is a DigitalOcean droplet (NYC3, Ubuntu 24.04, x86_64). Caddy
terminates TLS, caps request bodies and proxies to metal over the private
network (`deploy/Caddyfile`). When Linux serves, the same Caddy fronts the
local **zig server** on `localhost:9001` instead. The app gates `/admin` to
uid 1 (`admin_ui.requireAdmin`); the proxy leaves it open.

The host has **no zig, Go, Node or Elm toolchain**. We build locally and
ship a **single statically linked binary**, with the Elm and TS bundles, the
Safari and chess WASM cores and the puzzle catalogs embedded at compile
time (`build.zig`'s `@embedFile`). The site's own files (`pages/`,
`gallery/`, `downloads/`) are read from the working directory at request
time, and the deploy rsyncs them. Because the bundles are embedded,
`ops/build_elm`, `ops/build_delivery`, `ops/build_safari_wasm` and
`ops/build_chess_wasm` run before `zig build`; `ops/deploy` keeps that
order.

We ship a **Debug build**. The server is I/O-bound (static JS, small files,
small markdown renders), so LLVM's optimization passes would cost build time
and buy about nothing (unmeasured since the move to metal). Debug carries
the full set of runtime safety checks, a superset of ReleaseSafe's, and it
is the mode `ops/start` runs locally, so prod ships what we dogfood. Switch
`ops/deploy` to `-Doptimize=ReleaseSafe` when a CPU-bound path lands.

## A deploy while metal serves

**metal serves lynrummy.com, and prod's Linux `gopher-server` stays stopped
by design**: two hosts writing two copies of the data cannot be merged
(zig-metal-unikernel's
[CUTOVER.md](https://github.com/showell/zig-metal-unikernel/blob/master/CUTOVER.md)). So:

- **The program and the content** (`pages/`, `gallery/`) ship as a new
  **zig-metal-unikernel image**, built and deployed from that repo. metal
  serves the content from its own boot image, so `ops/deploy` leaves the
  content off prod, where nothing would serve it.
- **Only the watchdog** ships to the prod host, the aux box it runs on.

**`ops/deploy` fails closed.** It builds and restarts the Linux server ONLY
when prod says plainly that Linux serves: the marker `~/linux-serves`
present, `ssh` exit 0. **The marker's absence is the production state**
(metal serves): the script refreshes the watchdog and stops. An `ssh`
failure, or any answer it cannot read cleanly, **refuses** and names what
it saw; it never guesses "Linux serves". CUTOVER.md's way back (linked
above) creates the marker, the cutover removes it, and the watchdog reads
the same file the same way. `ops/test_deploy` pins every path, `ssh` failure included.

```
ops/deploy        # metal serving (marker absent): refreshes the watchdog only
```

## When Linux serves (the fallback, via CUTOVER.md's way back)

With `~/linux-serves` present on the prod host, `ops/deploy` is the full
deploy:

```
ops/deploy
```

It builds locally, rsyncs the binary and the content trees to the droplet
(the target is in `deploy/deploy.conf`) and restarts the `gopher-server`
systemd service.

## One-time host setup

Run once on a fresh droplet (the `steve` user has passwordless sudo; the
SSH key was added at droplet creation).

1. **Directories**

   ```
   ssh steve@<IP> 'mkdir -p ~/angry-gopher ~/AngryGopher/prod'
   ```

2. **Config**: copy the local `gopher.conf` and repoint `data_dir`. The
   config (`data_dir`, `auth_dir`) lives only on the host, never in git.
   The port is set apart from it: `GOPHER_PORT`, default 9001.

   ```
   scp ~/AngryGopher/gopher.conf steve@<IP>:~/AngryGopher/gopher.conf
   ssh steve@<IP> "sed -i 's|^data_dir.*|data_dir = /home/steve/AngryGopher/prod|' ~/AngryGopher/gopher.conf"
   ```

3. **systemd unit**

   ```
   scp deploy/gopher-server.service steve@<IP>:/tmp/
   ssh steve@<IP> 'sudo mv /tmp/gopher-server.service /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable gopher-server'
   ```

4. **First deploy** (puts the binary and files in place, starts the service)

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

   Then install the Caddyfile as `/etc/caddy/Caddyfile`. **Every site
   logs:** the Caddyfile defines the `access_log` snippet that each site
   block imports, both its own (lynrummy.com, and `knock`, the bare
   address's catch-all) and those in `/etc/caddy/sites/` (Dog Park's,
   roc's), so it goes in **before** a site file that imports it. **Make each
   log Caddy's first:** `caddy validate` runs as root and would create a
   missing log as root's, and the reload would then fail with "permission
   denied" (Caddy keeps its old config):

   ```
   scp deploy/Caddyfile steve@<IP>:/tmp/
   ssh steve@<IP> 'set -e
     for n in lynrummy knock dogpark roc; do
       f=/var/log/caddy/$n-access.log
       [ -f $f ] || sudo install -o caddy -g caddy -m 640 /dev/null $f
     done
     sudo caddy validate --adapter caddyfile --config /tmp/Caddyfile
     sudo install -m 644 /tmp/Caddyfile /etc/caddy/Caddyfile
     sudo systemctl reload caddy'
   ```

   `deploy/check_caddy_logs.py` (in `ops/check_common`) fails on a site
   block here that logs nowhere; name Dog Park's and roc's files to check
   theirs too. **What no log sees:** a TLS handshake naming a host no site
   has fails before HTTP, so nothing of it is written anywhere.

## Watchdog

`deploy/watchdog.py` is a small, stdlib-only health check that lives ON the
host as `steve`, and there alone. **Run it by hand when you want a
look.** As a service it polled every minute, four requests to metal's
`/version` each time, which was most of the site's traffic.

One run checks:

- the local server answers `GET /version`, or is stopped, as it should be
  while metal serves;
- exactly one `zig-server` process when it should be up;
- free RAM and disk;
- nothing unexpected running as `steve`;
- zig-metal-unikernel, when `~/metal-url` on the host names it (one line,
  `http://<metal's private address>`, the address `deploy/Caddyfile`
  proxies to): `metal` FAILs when metal's `/version` is silent and WARNs
  when metal runs another commit than this server; `metal-clock` WARNs at
  2 s and FAILs at 60 s between the two clocks; `metal-uptime` says how
  long metal has been up (short means a recent restart).

```
ssh steve@<IP> python3 watchdog.py          # every check once; the report; exit 0 only when all is OK
ssh steve@<IP> cat watchdog.log             # the WARN/FAIL runs so far
```

The report's header gives UTC and New York time; the `server` line includes
the build's git commit (baked in by `ops/deploy`'s `-Dcommit`). `ops/deploy`
copies the current `watchdog.py` to the host on every deploy, and a failed
copy fails the deploy. It takes no arguments (the thresholds are constants
at the top of the file), and its only network use is curling the local
server and metal's `/version`. `python3 deploy/test_watchdog.py` tests the
metal checks against two local servers, one of them stopped (run `zig
build` first).

## Hardening

- **TLS:** live on `https://lynrummy.com` (Let's Encrypt via Caddy,
  auto-renew); HTTP→HTTPS redirect; HSTS.
- **Security headers** (Caddyfile): HSTS, `X-Content-Type-Options`,
  `Referrer-Policy`, `X-Frame-Options`.
- **SSH:** key-only (password auth off via cloud-init drop-ins); root login
  disabled (`/etc/ssh/sshd_config.d/99-hardening.conf` → `PermitRootLogin
  no`). Log in as `steve`.
- **Auto updates:** `unattended-upgrades` enabled (DO image default).
- **Firewall:** ufw allows 22/80/443 only.
- **Backups:** the live data is on metal, and leaves it only through `GET
  /admin/backup` on lynrummy.com (zig-metal-unikernel's `DEPLOY.md`).
  `ops/backup` pulls a timestamped tarball of this host's `data_dir`
  (`~/AngryGopher/prod`) to `~/AngryGopher/backups` on the dev box; that is
  the Linux copy, frozen at the 2026-10-04 cutover. DigitalOcean's weekly
  droplet backups (control panel) are worth enabling for whole-droplet
  recovery of this host.
- **Account store (`~/Auth`):** the shared account data (`name`,
  `password`, `api-key`, and `~/Auth/next-id.txt`) lives under `~/Auth`
  (config `auth_dir`, default `~/Auth`), deliberately OUTSIDE `data_dir`.
  So the `ops/backup` tarball leaves it out: **back it up separately**, as
  it holds credentials. A sibling app can share accounts while
  `~/AngryGopher` stays its own. Gopher's private per-user data
  (upload-bytes) stays under `{data_dir}/users/<id>/`. A fresh host starts
  already split; the one-shot tool that split an older host is in git
  history.

### Deferred to the guests phase

A dedicated least-privilege service user; Caddy rate-limiting (`xcaddy` +
`caddy-ratelimit`).
