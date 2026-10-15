# Pairing server

[Back to README](../README.md)

The included [Python server](../server/coupledraw_server.py) uses the standard library and SQLite. The app defaults to `https://draw.huythedev.com`, or you can run this service on your own server. Keep one reachable process and a database for the pair; each phone authenticates with its own private credential, saved automatically by Create/Join or supplied manually for older pairs. SQLite holds token hashes, snapshot metadata, whiteboard strokes, settings, and optional alert destinations. Background photos and sticker images are stored once as private binary files in `<database path>.media/`, rather than base64 inside SQLite. The current app negotiates temporary media delivery: image files stay queued until both phones confirm that the originals are safely stored locally, then the server removes them. Latest drawing metadata and whiteboard strokes remain in SQLite. Unread latest photos stay queued for an offline recipient; superseded files are removed when no pending revision needs them. See [media and privacy](media-and-privacy.md).

**Back up both the database and its pending media directory.** A server backup cannot restore originals already deleted after delivery; those live on the phones. A backup created before deletion may still contain photos, so manage old backups according to your retention needs. Stop the service before copying them for a consistent backup. If copying a running SQLite database, its WAL data must also be handled correctly. Keep the media directory private; it does not need a public static-file route.

## Create a pair on a trusted local network

From the repository root:

```sh
python3 server/coupledraw_server.py serve --db coupledraw.sqlite3 --host 0.0.0.0
```

In CoupleDraw **Pair**, replace the default `https://draw.huythedev.com` with `http://COMPUTER_LAN_IP:8787`, with no `/v1/state` path, then tap **Create Pair**. Your partner enters the code on the same server or opens the invite link, which fills the server address automatically. The app issues and saves private credentials for both phones. See [pairing](pairing.md). Use the server computer's Wi-Fi IP, not `localhost` on the phone. Permit Local Network access and incoming Python connections if prompted. Keep both phones and the computer on the same non-isolated Wi-Fi and keep the process running.

For the legacy manual flow, run `python3 server/coupledraw_server.py create-pair --db coupledraw.sqlite3` once and save the printed A and B tokens privately. Each phone uses a different token under **Pair → Manual pairing with an existing token**. Existing pairs and tokens continue to work after an upgrade.

To supply your own secrets, run `python3 server/coupledraw_server.py create-pair --custom-tokens --db coupledraw.sqlite3` instead. It privately prompts for distinct A and B tokens with confirmation; use 20–100 characters from letters, digits, `.`, `_`, `~`, or `-`. Choose hard-to-guess strings. Do not put tokens in command arguments or commit them to Git. This creates a new pair, rather than changing an existing pair's credentials.

Local HTTP exposes drawings and tokens to anyone able to observe that network. Use it only on trusted private Wi-Fi. For Internet access, use an HTTPS reverse proxy; never publicly forward port 8787.

The service bounds concurrent connections to 64 and expires stalled socket I/O after 45 seconds, longer than its maximum 25-second long poll. Overload returns HTTP 503 with `Retry-After`; it does not change the syncing protocol. Request bodies have size limits and require one unambiguous Content-Length without Transfer-Encoding. Invalid numeric headers are ignored, and malformed or excessively nested JSON is rejected before changing artwork.

New databases are created with owner-only permissions (`0600`); existing file permissions are preserved for compatibility. Keep an existing database, backups, and alert configuration private to the service user. App requests do not follow redirects: use the final HTTPS address in Pair and have the proxy serve `/v1/*` directly.

## Docker (Linux containers on Windows, macOS, or Linux)

Install Docker Engine with the Compose plugin, or Docker Desktop using Linux containers. From the repository root:

```sh
docker compose up --build --detach --wait
docker compose logs --follow backend
```

The image listens on `0.0.0.0:8787` **inside** the container. Compose publishes it on host loopback at `127.0.0.1:8787`, ready for the HTTPS reverse proxy shown below. The app uses your proxy's HTTPS base URL. If the proxy runs in another container, connect it to the same Docker network and proxy to `backend:8787` instead of its own loopback. Allow long polls of up to 25 seconds.

For trusted Wi-Fi testing, put these settings in a root `.env` file, then rerun `docker compose up --detach --wait`:

```dotenv
COUPLEDRAW_BIND_IP=0.0.0.0
COUPLEDRAW_PORT=8787
```

Use `http://COMPUTER_LAN_IP:8787` in Pair. `COUPLEDRAW_PORT` changes only the published host port; keep the container port at 8787 for its health check. The `.env` file is ignored by Git. To return to the default private listener, remove `COUPLEDRAW_BIND_IP` and recreate the service.

### Published images

The **Backend Docker image** workflow tests native Linux AMD64 and ARM64 containers. After changes reach `main`, or a `v*` tag is pushed, it publishes `ghcr.io/huythedev/coupledraw-backend`. Tags include `latest` for main builds, `sha-<short commit>`, and the exact release tag. A pull request builds and tests without publishing. You can also run the workflow manually from main.

Once the first publish succeeds, use the published image by adding this to `.env`:

```dotenv
COUPLEDRAW_IMAGE=ghcr.io/huythedev/coupledraw-backend:latest
```

```sh
docker compose pull backend
docker compose up --detach --no-build --wait
```

New GHCR packages are private by default. For anonymous pulls, set the package visibility to public in GitHub's package settings; otherwise sign in with `docker login ghcr.io` using an account/token with package read access. The workflow publishes with the repository's `GITHUB_TOKEN`; no Docker Hub credentials are needed. For reproducible deployments, select a commit tag or image digest instead of `latest`.

### Data, upgrades, and maintenance

The named `coupledraw-data` volume mounts at `/data`. It holds `/data/coupledraw.sqlite3`, SQLite WAL/SHM files, and `/data/coupledraw.sqlite3.media/` together. The service runs as UID/GID `10001:10001`, with a read-only application filesystem. Docker initializes the named volume with the correct ownership. If replacing it with a bind mount, make that directory writable by UID/GID 10001 and retain the existing database/media filenames. Run one backend instance per volume.

For a source-build upgrade, run `docker compose up --build --detach --wait`. For a registry-image upgrade, pull and start with `--no-build` as above. Both preserve the volume. `docker compose down` also retains it; **do not use `down --volumes` for your deployment**, because that deletes its database and pending photos.

For a consistent backup, stop the service, archive the whole volume, then start it again. This example uses a one-off container running as the same service user:

```sh
docker compose stop backend
docker compose run --rm -T --no-deps --entrypoint tar backend -C /data -czf - . > coupledraw-backup.tgz
docker compose start backend
```

Run the archive command in a shell that preserves binary stdout, such as Bash or PowerShell 7.4+. Check the archive before relying on it. Restore the database and media directory together while the service is stopped, preserving ownership for UID/GID 10001. Backups do not contain images already deleted after delivery.

CLI maintenance uses the same volume. For example:

```sh
docker compose stop backend
docker compose run --rm --no-deps backend compact --db /data/coupledraw.sqlite3
docker compose start backend
```

For ntfy, stop the service, run `docker compose run --rm --no-deps backend configure-ntfy --db /data/coupledraw.sqlite3`, then start it again. For legacy manual pairs, use `create-pair --db /data/coupledraw.sqlite3` in the same way. Interactive commands need a terminal; do not use `-T` for private prompts.

The image already includes the optional APNs dependencies. To enable APNs, create an untracked `compose.override.yaml`:

```yaml
services:
  backend:
    environment:
      APNS_KEY_FILE: /run/secrets/apns.p8
      APNS_KEY_ID: YOUR_KEY_ID
      APNS_TEAM_ID: YOUR_TEAM_ID
      APNS_TOPIC: YOUR_APP_BUNDLE_ID
    volumes:
      - ./secrets/AuthKey.p8:/run/secrets/apns.p8:ro
```

Keep the key in the ignored `secrets/` directory, readable by the container's UID 10001, and recreate the service. For an environment override of the persisted ntfy server, add `NTFY_BASE_URL` to the same `environment` mapping. See the alert sections below for the required iOS signing and setup.

### Build or validate the image directly

```sh
docker build --tag coupledraw-backend:local ./server
docker run --detach --name coupledraw-backend --restart unless-stopped -p 127.0.0.1:8787:8787 --mount source=coupledraw-data,target=/data coupledraw-backend:local
```

For development, `python3 tools/test-server-docker.py` builds Compose in a randomly named disposable project, checks health, non-root operation, APNs imports and maintenance, then recreates the service and checks that pairing credentials, drawing metadata, and pending photo bytes persist. It deletes only that test project's volume when finished.

## Ubuntu VPS with HTTPS

Copy the **entire** `server/coupledraw_server.py` to `~/coupledraw/coupledraw_server.py`. On the VPS:

```sh
cd ~/coupledraw
python3 -m py_compile coupledraw_server.py
python3 coupledraw_server.py serve --db coupledraw.sqlite3
```

Create pairs from the app; no token setup command is needed. With no `--host` option, the process listens on `127.0.0.1:8787`, ready for a reverse proxy. Stop the foreground process before setting up a service. Example `/etc/systemd/system/coupledraw.service` (replace `YOUR_USER` and paths):

```ini
[Unit]
Description=CoupleDraw pairing server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=YOUR_USER
WorkingDirectory=/home/YOUR_USER/coupledraw
ExecStart=/usr/bin/python3 /home/YOUR_USER/coupledraw/coupledraw_server.py serve --db /home/YOUR_USER/coupledraw/coupledraw.sqlite3
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

Run `sudo systemctl daemon-reload`, `sudo systemctl enable --now coupledraw`, and `sudo systemctl status coupledraw`. Follow logs with `journalctl -u coupledraw -f`. Point your domain at the VPS, configure HTTPS in your reverse proxy, and route it to loopback. For example, a Caddy site:

```caddyfile
draw.example.com {
    reverse_proxy 127.0.0.1:8787
}
```

Use `https://draw.example.com` in **Pair**, then **Create Pair / Join Pair**. If you host at `draw.huythedev.com`, the app already selects it by default. Keep port 8787 private. Test an Apply on one phone and open the other to confirm it receives the revision. When upgrading, replace the complete server script and restart the service **without deleting the SQLite database or changing tokens**; upgrade both apps alongside the server to retain the shared whiteboard protocol.

Create/Join endpoints are available without an existing token. The server limits new creates and joins to five per minute per TCP peer and thirty globally; invalid six-digit guesses count. The same limit applies across processes through SQLite. Up to 100 unexpired/recoverable sessions are retained. Behind a reverse proxy, the TCP peer can be shared by all phones: add per-client limits at the proxy if hosting for many people. Forwarded-IP headers are not trusted. The server is intended for private use; these limits do not provide a public registration or abuse-management system. Pairing codes, recovery secrets and credentials are never printed in request logs.

On the first startup of this version, embedded photos in older snapshots migrate to the media directory automatically, and SQLite is compacted to reclaim old photo space. Keep that directory beside the database on subsequent restarts. You may specify a different private directory with `--media-dir /path/to/coupledraw-media`; use the same option for `serve` and `compact`.

To reclaim unused media and SQLite free pages manually, stop the service, run the following in the directory containing the standalone script, then restart it:

```sh
python3 coupledraw_server.py compact --db coupledraw.sqlite3
```

This preserves current drawing metadata, tokens, and photos still awaiting delivery. Delivered originals are already removed after exact-revision receipts from both phones; compact also retries deferred cleanup. Older History remains on each phone. Keep both apps updated: a legacy app cannot send these receipts, so its images remain queued. A phone missing a delivered original asks its partner to resend it while the partner app is open, instead of recovering it from a permanent VPS copy. Update the server before sharing stickers; the app detects an older server and keeps the sticker draft locally instead of publishing it without images.

For temporary remote testing from a Mac, keep the default loopback server running and start `cloudflared tunnel --url http://127.0.0.1:8787` in another terminal. Enter the generated HTTPS address in Pair on both phones. That address may change when the tunnel restarts.

For a private Tailscale deployment, connect the server and both iPhones to the same tailnet, bind the server to **its own** Tailscale IP with `--host SERVER_TAILSCALE_IP`, and use `http://SERVER_TAILSCALE_IP:8787` on each phone. Check the server's actual address and firewall. Do not expose the HTTP listener through a public funnel. The app accepts HTTP only for loopback, private IPv4, the Tailscale `100.64.0.0/10` range, or `.local` hosts.

## Optional ntfy alerts with a Personal Team

For an alert when the receiving app is closed, install the separate ntfy iPhone app on both phones. On the server, after the pair exists:

```sh
python3 coupledraw_server.py configure-ntfy --db coupledraw.sqlite3
sudo systemctl restart coupledraw
```

Enter an HTTPS **server base URL** at the prompt, usually `https://ntfy.sh`, not a URL with a topic path. The server generates a different private topic for each phone and publishes to `base URL/topic`. If running manually, restart the `serve` process rather than systemd. `NTFY_BASE_URL` is an optional environment override. The VPS needs outbound HTTPS access to the chosen ntfy server.

Open **Pair → Alerts through ntfy** on *each phone*, copy that phone's topic, subscribe to it in the ntfy app on the configured base URL, and allow notifications. A's Apply sends an alert to B's topic and vice versa. Treat the topic as a password: on public ntfy.sh, someone who learns it can subscribe or publish. Messages contain no token or artwork. See [wallpaper and automations](wallpaper-and-automations.md) for the Shortcuts trigger; the alert itself does not change wallpaper.

## Optional direct APNs

This requires an Apple Developer Program team and matching Push-capable provisioning, not a Personal Team. Generate the project with `python3 tools/generate_xcodeproj.py --enable-push`, sign with a matching Push entitlement, and keep the APNs `.p8` key on the server. Install server extras with `python3 -m pip install -r server/requirements-push.txt`; set `APNS_KEY_FILE`, `APNS_KEY_ID`, `APNS_TEAM_ID`, and `APNS_TOPIC` (the installed app's bundle ID) in the service environment. Restart the service. Pair both signed phones and enable partner Apply alerts. Never commit the private key. The default project does not enable Push and works with a Personal Team.

## Logs and troubleshooting

Server request logs show UTC time, authenticated `client=A` or `client=B` (or `-` if unauthenticated), method, endpoint, HTTP status, and `duration_ms`; Apply includes source and revision. State requests also include wait timing. Tokens, artwork, media hashes, and query strings are omitted. `/v1/media/ack` logs the receipt count and removed byte count. Recovery uses authenticated `/v1/media/request` and `/v1/media/restore`; there is no public image download route. Foreground clients normally make a waiting request of up to 20 seconds; an edit or Apply wakes it promptly, and unchanged state can return HTTP 304. The app's **live while open** status indicates the server supports waiting; **checking every 30s** suggests an older server or a proxy missing the wait header. The server may shorten waits if a proxy closes them early.

If pairing fails, check the server address, code expiry, network reachability, firewall, and whether the server is still running. A server upgrade message for Create/Join means replacing the complete script and restarting it. For manual pairing, check which token belongs to that phone. If Our art reports an upgrade error, install the current complete server script and update both apps while keeping the existing database. If an alert fails, check the server logs and the receiving phone's ntfy subscription or APNs registration. Alert acceptance does not guarantee iOS will run an automation.
