# Deploying Angry Gopher (Lyn Rummy)

The production host is a DigitalOcean droplet (NYC3, Ubuntu 24.04,
x86_64). Caddy fronts the **zig server** (see `SERVER.md`) for TLS and a
body cap; the server listens on `localhost:9001`. (`/admin` is gated by
the app's per-user admin flag, not the proxy.)

The host runs **no zig/Go/Node/Elm toolchain** — we build locally and
ship a **single self-contained binary**: the Elm/TS/driving bundles +
puzzle catalogs are baked in at compile time (`build.zig` `@embedFile`),
and the binary is statically linked, so there are no runtime file
dependencies and no working-dir assumptions. Because the bundles are
embedded at compile time, `ops/build_elm` + `ops/build_driving` run
*before* `zig build` (the deploy script handles this ordering). See
`ops/deploy`.

> The host was originally the Go server on `:9000`; the Go→zig cutover
> repointed Caddy to `:9001` and the systemd `ExecStart` to the zig
> binary. The old Go binary is left on disk as an instant rollback.

## Repeat deploys

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
   The config (`port`, `data_dir`) lives only on the host, never in git.

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
  gopher-private per-user data (admin, last-seen, upload-bytes) stays under
  `{data_dir}/users/<id>/`. A fresh host starts already-split; the prod host
  was migrated 2026-05-29 (the one-shot migration tool has since been removed —
  pull it from git history if another existing host ever needs it).

### Deferred to the guests phase

`go:embed` self-contained binary; a dedicated least-privilege service
user; Caddy rate-limiting (`xcaddy` + `caddy-ratelimit`).
