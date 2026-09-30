# CoupleDraw

CoupleDraw is a two-person iPhone drawing app. Make a drawing for your partner, use theirs, or work together on **Our art**. Each phone independently chooses which applied drawing its Lock Screen Shortcut uses. Pairing is optional for drawing alone; sharing requires the included Python server.

The app supplies a **Get My CoupleDraw Wallpaper** action to Shortcuts. It cannot change iOS wallpaper on its own. Applying a drawing publishes a saved version; the receiving phone still needs its Shortcut's **Set Wallpaper** action to run. iOS may require a preview or confirmation, especially while locked.

## Get started

You need an iPhone with iOS 17 or later. To build from source, use a Mac with the full Xcode 16 or later. Open `CoupleDraw.xcodeproj`, select the **CoupleDraw** scheme, set your own bundle IDs and signing Team for both the app and `CoupleDrawWidget`, connect the iPhone, then choose **Product → Run**. The default project does not require Push Notifications, so it can be signed with a Personal Team. For a prebuilt unsigned IPA, see [build and signing](docs/build-and-sign.md); an unsigned IPA cannot be installed directly.

1. Open **Canvas → My art** and tap **Draw**. Tap **Done** to keep the draft, then **Apply** to save a wallpaper version. You can also choose a background from Camera, Photos, or Files.
2. To share with a partner, run the server below, then open **Pair** on each phone. Enter the same server address, token **A** on one phone, and token **B** on the other.
3. In **My Lock Screen shows**, independently choose **My art**, **Partner's art**, or **Our art** on each phone. Partner's art becomes available after the partner applies their My art. Both people can edit Our art while the apps are open; either person can apply it.
4. On each phone, create a Shortcut: **Get My CoupleDraw Wallpaper → Set Wallpaper** (choose Lock Screen). Run it once manually before adding an automation. Turn off **Show Preview** in Set Wallpaper if your iOS version offers it.

See [using the app](docs/using-the-app.md) for drawing, shared editing, History, photos, and the Lock Screen widget; [wallpaper and automations](docs/wallpaper-and-automations.md) covers ntfy and what happens while the phone is locked.

## Pairing server

The included `server/coupledraw_server.py` needs Python 3 and SQLite (Python's standard library). It stores drawings and issues separate private tokens for A and B. Create a pair **once**, keep its database, and give each person only their own token.

For testing on the same trusted Wi-Fi, from the repository root run:

```sh
python3 server/coupledraw_server.py create-pair --db coupledraw.sqlite3
python3 server/coupledraw_server.py serve --db coupledraw.sqlite3 --host 0.0.0.0
```

In **Pair** on each phone enter `http://YOUR_COMPUTER_LAN_IP:8787` and its own token. Use the computer's LAN address, not `localhost`; allow Local Network access if prompted. Keep the server running. This HTTP setup is only for a trusted local network; use HTTPS for an Internet-facing server. To choose your own private tokens, add `--custom-tokens` to the `create-pair` command; it prompts for two distinct tokens without putting them in shell history.

On a VPS, copy the **complete** script, create the pair once, run `serve` with its default `127.0.0.1:8787` binding, and put an HTTPS reverse proxy in front of it. Enter that HTTPS base address in Pair. Keep the database and tokens when upgrading the app and server together. See [server setup](docs/server.md) for Ubuntu/systemd, Caddy, Tailscale, backup, logging, and optional alerts.

## How updates work

**My art** is yours to edit; your partner sees it after you Apply. **Partner's art** is view-only on your phone. **Our art** syncs completed stroke edits while the app is open; Apply saves a shared wallpaper snapshot. Each phone renders the chosen wallpaper at its own screen size.

While open, the app waits for server changes and refreshes promptly. While closed or suspended, it does not keep a background connection: the Shortcut fetches the latest selected drawing **when invoked**. Optional ntfy or APNs alerts can announce a partner's Apply, but delivery and automation behavior depend on iOS. The app does not use background location tracking.

## More guides

- [Using the app](docs/using-the-app.md) — canvas choices, photos, shared board, History, and widget.
- [Server setup](docs/server.md) — local network, Ubuntu VPS, private tokens, ntfy, APNs, and logs.
- [Wallpaper and automations](docs/wallpaper-and-automations.md) — Shortcuts, notification triggers, locked phones, and limitations.
- [Build and signing](docs/build-and-sign.md) — Xcode, unsigned IPA, signing both targets, and releases.
- [Development](docs/development.md) — tests, project generation, sync details, and current scope.

Licensed under [MIT](LICENSE).
