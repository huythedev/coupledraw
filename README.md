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

On a VPS, copy the **complete** script, run `serve` with its default `127.0.0.1:8787` binding, and put an HTTPS reverse proxy in front of it. Enter that HTTPS base address in Pair. The app creates pairs, so no `create-pair` command is needed. Keep the database and media directory when upgrading the app and server together. See [server setup](docs/server.md) for Ubuntu/systemd, Caddy, Tailscale, backup, logging, and optional alerts.

## How updates work

**My art** is yours to edit; your partner sees it after you Apply. **Partner's art** is view-only on your phone. **Our art** syncs completed stroke edits while the app is open; Apply saves a shared wallpaper snapshot. Each phone renders the chosen wallpaper at its own screen size.

While open, the app waits for server changes and refreshes promptly. While closed or suspended, it does not keep a background connection: the Shortcut fetches the latest selected drawing **when invoked**. Optional ntfy or APNs alerts can announce a partner's Apply, but delivery and automation behavior depend on iOS. The app does not use background location tracking.

## More guides

- [Using the app](docs/using-the-app.md) — canvas choices, photos, shared board, History, and widget.
- [Pairing](docs/pairing.md) — Create/Join, private credentials, invite links, and recovery.
- [Server setup](docs/server.md) — local network, Ubuntu VPS, private tokens, ntfy, APNs, and logs.
- [Wallpaper and automations](docs/wallpaper-and-automations.md) — Shortcuts, notification triggers, locked phones, and limitations.
- [Build and signing](docs/build-and-sign.md) — Xcode, unsigned IPA, signing both targets, and releases.
- [Development](docs/development.md) — tests, project generation, sync details, and current scope.

Licensed under [MIT](LICENSE).
