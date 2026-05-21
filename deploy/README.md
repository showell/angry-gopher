# Deploying Angry Gopher (Lyn Rummy)

The production host is a DigitalOcean droplet (NYC3, Ubuntu 24.04,
x86_64). Caddy fronts the Go server for TLS, `/admin` basic-auth,
and a body cap; the Go server listens on `localhost:9000`.

The host runs **no Go/Node/Elm** — we build locally and ship the
binary plus the seven static files the server reads at runtime
(three gitignored Elm/TS bundles, `engine_glue.js`, and the three
puzzle-catalog `.dsl` files). See `ops/deploy`.

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

## Going from IP to domain (later)

Once `lynrummy.com` resolves to the droplet, edit
`/etc/caddy/Caddyfile` on the host: change the site address `:80`
to `lynrummy.com`, uncomment the HSTS header, `sudo systemctl
reload caddy`. Caddy provisions the cert on first request.
