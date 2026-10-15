# CoupleDraw

CoupleDraw is a two-person iPhone drawing app. Make a drawing for your partner, use theirs, or work together on **Our art**. Each phone independently chooses which applied drawing its Lock Screen Shortcut uses. Pairing is optional for drawing alone; sharing requires the included Python server.

The app supplies a **Get My CoupleDraw Wallpaper** action to Shortcuts. It cannot change iOS wallpaper on its own. Applying a drawing publishes a saved version; the receiving phone still needs its Shortcut's **Set Wallpaper** action to run. iOS may require a preview or confirmation, especially while locked.

## Get started

You need an iPhone with iOS 17 or later. To build from source, use a Mac with the full Xcode 16 or later. Open `CoupleDraw.xcodeproj`, select the **CoupleDraw** scheme, set your own bundle IDs and signing Team for both the app and `CoupleDrawWidget`, connect the iPhone, then choose **Product → Run**. The default project does not require Push Notifications, so it can be signed with a Personal Team. For a prebuilt unsigned IPA, see [build and signing](docs/build-and-sign.md); an unsigned IPA cannot be installed directly.

1. Open **Canvas → My art** and tap **Draw**. Tap **Done** to keep the draft, then **Apply** to save a wallpaper version. You can also choose a background from Camera, Photos, or Files.
2. To share with a partner, open **Pair**. The default server is `https://draw.huythedev.com`; type another address if you host your own. One person taps **Create Pair**, then shares the six-digit code or invite. The other taps **Join Pair** and enters the code, or opens the invite link. Credentials are saved automatically. Existing A/B tokens still work under **Manual pairing**.
3. In **My Lock Screen shows**, independently choose **My art**, **Partner's art**, or **Our art** on each phone. Partner's art becomes available after the partner applies their My art. Both people can edit Our art while the apps are open; either person can apply it.
4. On each phone, create a Shortcut: **Get My CoupleDraw Wallpaper → Set Wallpaper** (choose Lock Screen). Run it once manually before adding an automation. Turn off **Show Preview** in Set Wallpaper if your iOS version offers it.

See [using the app](docs/using-the-app.md) for drawing, shared editing, History, photos, and the Lock Screen widget; [wallpaper and automations](docs/wallpaper-and-automations.md) covers ntfy and what happens while the phone is locked.

In the drawing editor, **Stickers** lets you paste or import an image, use supported keyboard stickers, then drag, rotate, and resize each sticker. **Setup → Clear cache** frees rendered wallpaper images while keeping editable art and History.

## Pairing server

The included `server/coupledraw_server.py` needs Python 3 and SQLite (Python's standard library). It stores drawings and supports the app's **Create Pair / Join Pair** flow. Six-digit codes expire after five minutes and are consumed atomically when someone joins. Each phone receives a different long-lived private credential, stored in its Keychain. See [pairing](docs/pairing.md) for invitations and interrupted connections.

For testing on the same trusted Wi-Fi, from the repository root run:

```sh
python3 server/coupledraw_server.py serve --db coupledraw.sqlite3 --host 0.0.0.0
```

In **Pair** enter `http://YOUR_COMPUTER_LAN_IP:8787`, then create an invite. Its link and QR code include that server address; when entering just the six-digit code, both phones must select the same server. Use the computer's LAN address, not `localhost`; allow Local Network access if prompted. Keep the server running. This HTTP setup is only for a trusted local network; use HTTPS for an Internet-facing server. The optional `create-pair --custom-tokens` command still prompts for private A/B tokens for manual pairing.

On a VPS, copy the **complete** script, run `serve` with its default `127.0.0.1:8787` binding, and put an HTTPS reverse proxy in front of it. Enter that HTTPS base address in Pair. The app creates pairs, so no `create-pair` command is needed. Keep the database and media directory during upgrades. App and server builds can differ: supported features keep working, and an unavailable feature asks for the relevant update. See [compatibility](docs/compatibility.md) and [server setup](docs/server.md) for details.

## Docker backend setup

Use Docker Desktop on Windows/macOS (with **Linux containers**) or Docker Engine with the Compose plugin on Linux. Docker runs the Python backend; the iPhone app is installed separately. Check that `docker version` and `docker compose version` work before continuing.

### 1. Download and start the server

```sh
git clone https://github.com/huythedev/coupledraw.git
cd coupledraw
docker compose up --build --detach --wait
```

If you already cloned the repository, run the Compose command from its root directory. The first run builds the image and creates the data volume. Check status and logs with:

```sh
docker compose ps
docker compose logs --follow backend
```

Press Ctrl+C to leave the log view; the server keeps running. Compose restarts the backend when Docker starts.

### 2. Connect your iPhones

**Trusted Wi-Fi:** create a file named `.env` beside `compose.yaml` containing:

```dotenv
COUPLEDRAW_BIND_IP=0.0.0.0
COUPLEDRAW_PORT=8787
```

Apply the settings:

```sh
docker compose up --detach --wait
```

Keep both phones and the server on the same trusted network. Allow inbound TCP port 8787 on the server's private-network firewall. In **Pair** on both phones, enter `http://YOUR_COMPUTER_LAN_IP:8787`. One person taps **Create Pair**; the other taps **Join Pair** and enters the code. Use the computer's LAN IP rather than `localhost`, and permit Local Network access on iOS.

**Internet/VPS:** keep the default loopback binding and put an HTTPS reverse proxy in front of `127.0.0.1:8787`. For example, with Caddy installed on the host and your domain pointing at the server:

```caddyfile
draw.example.com {
    reverse_proxy 127.0.0.1:8787
}
```

Use `https://draw.example.com` in Pair on both phones. Keep host port 8787 private. If the proxy runs in Docker, connect it to the backend's network and proxy to `backend:8787`. See [server setup](docs/server.md) for proxy and networking details.

These optional settings go in the root `.env` file:

| Setting | Default | Purpose |
| --- | --- | --- |
| `COUPLEDRAW_BIND_IP` | `127.0.0.1` | Host listener address; use `0.0.0.0` for trusted LAN access. |
| `COUPLEDRAW_PORT` | `8787` | Published host port; the container always uses port 8787. |
| `COUPLEDRAW_IMAGE` | `coupledraw-backend:local` | Image name for a local build or a published image. |

### 3. Update or stop the server

To update a server built from source:

```sh
git pull --ff-only
docker compose up --build --detach --wait
```

To stop temporarily, run `docker compose stop backend`; resume with `docker compose start backend`. To remove the container while retaining its data, run `docker compose down`.

The named `coupledraw-data` volume stores SQLite and pending photos together at `/data`. Rebuilding or recreating the container preserves this volume. **Do not run `docker compose down --volumes` unless you intend to delete the server's pairs, drawings, and pending photos.** Back up the whole volume while the service is stopped; follow the [backup and maintenance instructions](docs/server.md#data-upgrades-and-maintenance). Keep using the same Compose project/directory when upgrading so it selects the same volume.

### Use a published image instead of building

After a successful **Backend Docker image** workflow on `main`, AMD64 and ARM64 images are available at `ghcr.io/huythedev/coupledraw-backend`. Add this line to `.env` alongside any network settings:

```dotenv
COUPLEDRAW_IMAGE=ghcr.io/huythedev/coupledraw-backend:latest
```

Then install or update the published image:

```sh
docker compose pull backend
docker compose up --detach --no-build --wait
```

The workflow also publishes commit tags (`sha-<short commit>`) and release tags (`v*`). Choose one of those tags or a digest when you need a fixed version. If the package is private, authenticate with `docker login ghcr.io` using credentials with package read access; the owner can make it public in GitHub's package settings.

The image includes APNs dependencies. For ntfy, APNs keys, custom storage, and standalone `docker run` commands, see the [full Docker guide](docs/server.md#docker-linux-containers-on-windows-macos-or-linux).

## How updates work

**My art** is yours to edit; your partner sees it after you Apply. **Partner's art** is view-only on your phone. **Our art** syncs completed stroke edits while the app is open; Apply saves a shared wallpaper snapshot. Each phone renders the chosen wallpaper at its own screen size.

Photos and stickers use temporary delivery storage: each phone keeps the originals for the latest paired canvases, and the server removes its image files after both phones confirm local storage. Clear cache preserves these originals. Lost copies can be requested from the other phone; the server is no longer a photo backup after delivery. See [media and privacy](docs/media-and-privacy.md). This reduces retention; it is not end-to-end encryption.

While open, the app waits for server changes and refreshes promptly. While closed or suspended, it does not keep a background connection: the Shortcut fetches the latest selected drawing **when invoked**. Optional ntfy or APNs alerts can announce a partner's Apply, but delivery and automation behavior depend on iOS. The app does not use background location tracking.

## More guides

- [Using the app](docs/using-the-app.md) — canvas choices, photos, shared board, History, and widget.
- [Pairing](docs/pairing.md) — Create/Join, private credentials, invite links, and recovery.
- [Media and privacy](docs/media-and-privacy.md) — temporary images, phone storage, receipts, and recovery.
- [Server setup](docs/server.md) — local network, Ubuntu VPS, private tokens, ntfy, APNs, and logs.
- [Wallpaper and automations](docs/wallpaper-and-automations.md) — Shortcuts, notification triggers, locked phones, and limitations.
- [Build and signing](docs/build-and-sign.md) — Xcode, unsigned IPA, signing both targets, and releases.
- [Development](docs/development.md) — tests, project generation, sync details, and current scope.
- [Sync and resource limits](docs/sync-and-resources.md) — WAL reads, safe board cleanup, Shortcut memory, retry policy, and app sandbox.
- [Compatibility](docs/compatibility.md) — mixed app/server versions, older partners, fallbacks, and feature-specific update prompts.

Licensed under [MIT](LICENSE).
