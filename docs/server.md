# Pairing server

[Back to README](../README.md)

The included [Python server](../server/coupledraw_server.py) uses the standard library and SQLite. It has no hosted instance or account system. Keep one reachable process and a database for the pair; each phone authenticates with its own A or B token. SQLite holds token hashes, snapshot metadata, whiteboard strokes, settings, and optional alert destinations. Background photos and sticker images are stored once as private binary files in `<database path>.media/`, rather than base64 inside SQLite. The service retains media referenced by the latest artwork, so offline or reinstalled phones can retrieve it; unreferenced files are removed automatically after replacement.

**Back up both the database and its media directory.** Stop the service before copying them for a consistent backup. If copying a running SQLite database, its WAL data must also be handled correctly. Keep the media directory private; it does not need a public static-file route.

## Create a pair on a trusted local network

From the repository root:

```sh
python3 server/coupledraw_server.py create-pair --db coupledraw.sqlite3
python3 server/coupledraw_server.py serve --db coupledraw.sqlite3 --host 0.0.0.0
```

Run `create-pair` once; save the printed A and B tokens privately. Give each phone a different token. In CoupleDraw **Pair**, enter `http://COMPUTER_LAN_IP:8787`, with no `/v1/state` path. Use the server computer's Wi-Fi IP, not `localhost` on the phone. Permit Local Network access and incoming Python connections if prompted. Keep both phones and the computer on the same non-isolated Wi-Fi and keep the process running.

To supply your own secrets, run `python3 server/coupledraw_server.py create-pair --custom-tokens --db coupledraw.sqlite3` instead. It privately prompts for distinct A and B tokens with confirmation; use 20–100 characters from letters, digits, `.`, `_`, `~`, or `-`. Choose hard-to-guess strings. Do not put tokens in command arguments or commit them to Git. This creates a new pair, rather than changing an existing pair's credentials.

Local HTTP exposes drawings and tokens to anyone able to observe that network. Use it only on trusted private Wi-Fi. For Internet access, use an HTTPS reverse proxy; never publicly forward port 8787.

The service bounds concurrent connections to 64 and expires stalled socket I/O after 45 seconds, longer than its maximum 25-second long poll. Overload returns HTTP 503 with `Retry-After`; it does not change the syncing protocol. Request bodies have size limits and require one unambiguous Content-Length without Transfer-Encoding. Invalid numeric headers are ignored, and malformed or excessively nested JSON is rejected before changing artwork.

New databases are created with owner-only permissions (`0600`); existing file permissions are preserved for compatibility. Keep an existing database, backups, and alert configuration private to the service user. App requests do not follow redirects: use the final HTTPS address in Pair and have the proxy serve `/v1/*` directly.

## Ubuntu VPS with HTTPS

Copy the **entire** `server/coupledraw_server.py` to `~/coupledraw/coupledraw_server.py`. On the VPS:

```sh
cd ~/coupledraw
python3 -m py_compile coupledraw_server.py
python3 coupledraw_server.py create-pair --db coupledraw.sqlite3
python3 coupledraw_server.py serve --db coupledraw.sqlite3
```

Create the pair only the first time. Save both tokens. With no `--host` option, the process listens on `127.0.0.1:8787`, ready for a reverse proxy. Stop the foreground process before setting up a service. Example `/etc/systemd/system/coupledraw.service` (replace `YOUR_USER` and paths):

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

Use `https://draw.example.com` and each phone's A/B token in **Pair**. Keep port 8787 private. Test an Apply on one phone and open the other to confirm it receives the revision. When upgrading, replace the complete server script and restart the service **without deleting the SQLite database or changing tokens**; upgrade both apps alongside the server to retain the shared whiteboard protocol.

On the first startup of this version, embedded photos in older snapshots migrate to the media directory automatically, and SQLite is compacted to reclaim old photo space. Keep that directory beside the database on subsequent restarts. You may specify a different private directory with `--media-dir /path/to/coupledraw-media`; use the same option for `serve` and `compact`.

To reclaim unused media and SQLite free pages manually, stop the service, run the following in the directory containing the standalone script, then restart it:

```sh
python3 coupledraw_server.py compact --db coupledraw.sqlite3
```

This preserves current artwork and tokens. It does not delete the latest photos after a partner receives them, because those files also support later re-sync and reinstall. Older History remains on each phone. Update the server before sharing stickers; the app detects an older server and keeps the sticker draft locally instead of publishing it without images.

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

Server request logs show UTC time, authenticated `client=A` or `client=B` (or `-` if unauthenticated), method, endpoint, HTTP status, and `duration_ms`; Apply includes source and revision. State requests also include wait timing. Tokens, artwork, and query strings are omitted. Foreground clients normally make a waiting request of up to 20 seconds; an edit or Apply wakes it promptly, and unchanged state can return HTTP 304. The app's **live while open** status indicates the server supports waiting; **checking every 30s** suggests an older server or a proxy missing the wait header. The server may shorten waits if a proxy closes them early.

If pairing fails, check the address, which token belongs to that phone, network reachability, firewall, and whether the server is still running. If Our art reports an upgrade error, install the current complete server script and update both apps while keeping the existing database. If an alert fails, check the server logs and the receiving phone's ntfy subscription or APNs registration. Alert acceptance does not guarantee iOS will run an automation.
