# Deploying Angry Gopher (Lyn Rummy)

The production host is a DigitalOcean droplet (NYC3, Ubuntu 24.04,
x86_64). Caddy fronts the Go server for TLS, `/admin` basic-auth,
and a body cap; the Go server listens on `localhost:9000`.

The host runs **no Go/Node/Elm** — we build locally and ship a
**single self-contained binary**: the Elm/TS bundles + puzzle
catalogs are baked in via `go:embed` (see `embed.go`), so there are
no runtime file dependencies and no working-dir assumptions. Because
the bundles are embedded at compile time, `ops/build_elm` must run
*before* `go build` (the build scripts handle this ordering). See
`ops/deploy`.

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
   The Zulip API key rides along; it lives only on the host, never
   in git.

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

   Then install the Caddyfile (with the real `/admin` bcrypt hash
   substituted in — generate with `caddy hash-password`):

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

### Deferred to the guests phase

`go:embed` self-contained binary; a dedicated least-privilege service
user; Caddy rate-limiting (`xcaddy` + `caddy-ratelimit`).
