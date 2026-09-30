# CoupleDraw — local iOS prototype

This repository is a **prototype**, not the complete two-person service in the supplied specification. It has three distinct art sources: **My art** (only this person publishes), **Partner's art** (view-only on this phone), and **Our art** (both publish). The main screen separates **Canvas** from **My Lock Screen shows**. Choosing the latter only changes what this phone's Shortcut returns. A local App Intent gives the selected, last applied image to Shortcuts. Mine and Together render at this iPhone's native pixel dimensions; Partner's preview size is configurable, but the Shortcut renders any selected source at the receiving phone's size. There is a small optional sync service for two paired devices. While open, it waits on one state request for up to 20 seconds and the server answers immediately after a shared edit or Apply. Our art is a shared editable whiteboard: completed strokes, moves and erases sync as operations after a 150 ms batching window. Either person can edit any stroke or Apply the board for both phones. Apply publishes a whole-canvas snapshot. The app cannot set system wallpaper, remotely start Shortcuts, or guarantee background operation.

## Build on a Mac

1. Install Xcode 16 or newer on a Mac. Open **`CoupleDraw.xcodeproj`** directly; no package manager is needed to build the iOS app. The optional paired server is the included Python and SQLite service.
   The Home Screen icon is included in `Assets.xcassets/AppIcon.appiconset`; the app target selects `AppIcon` in both the included Xcode project and `project.yml`. Its artwork follows the Lock Screen widget's heart-in-a-circle design. To regenerate the PNG artwork, run `python3 tools/generate_app_icon.py` with Pillow and NumPy installed.
2. For a simulator build, run `sh tools/build-on-mac.sh` or choose the CoupleDraw scheme and an iPhone Simulator in Xcode. The shared scheme includes the unit tests.
3. For a physical iPhone, set your own unique Bundle Identifier and Apple Developer signing Team in the CoupleDraw target. The included Xcode project has **Push Notifications off by default**, so a Personal Team can provision it. Set **CoupleDrawWidget** to the same Team and a Bundle Identifier consisting of the app identifier plus `.Widget` (for example `com.yourname.CoupleDraw.Widget`). Choose a phone running iOS 17 or later and use **Product → Run** (`⌘R`) to build, sign, install, and launch the app. Run tests with `⌘U`. Both targets must use compatible signing and provisioning.
4. Under **Canvas**, select My art or Our art, tap **Draw** (or tap the preview), make your drawing, and tap **Done**. Two fingers pan or zoom; **Fit** resets the view. When zoomed in, the miniature canvas shows your current position. Tap **Photo**, then **Camera**, **Photos**, or **Files** to choose a background. A camera capture stays in the draft (it is not saved to Photos automatically); camera permission is requested only when you tap Camera. After capture or import, drag to pan, pinch to zoom, and twist to rotate. The zoom slider goes down to 10% of the initial fill size, and the rotation slider gives precise control. The visible frame shows what will appear behind existing strokes; tap **Save** when it looks right. You can reframe or remove it later without changing your strokes. **Clear** removes local strokes from My art. In live Our art, **Clear all** removes the visible shared strokes on both phones after confirmation. Undo/Redo operates on your edits and preserves unrelated partner strokes. Backgrounds and saved History remain. Tap **Apply** on the main screen to save and share that canvas. Under **My Lock Screen shows**, choose My art, Partner's art, or Our art independently. On the same phone, create a Shortcut with **Get My CoupleDraw Wallpaper → Set Wallpaper** (Lock Screen). Expand Set Wallpaper and turn **Show Preview** off **if available**. Run it by itself first. Only add a personal automation if the Shortcut itself runs without a Save screen. An **App → Is Closed** trigger runs after you leave CoupleDraw following Apply. The Shortcut checks the paired service when invoked, including if the app has been closed.
5. If upgrading from the earlier 390 × 844 build, open the updated app and tap Apply again. Existing editable strokes are scaled into the new target aspect ratio; earlier exported PNG revisions keep their original pixels.

## Lock Screen quick-open widget

The included **CoupleDrawWidget** extension has circular, rectangular, and inline Lock Screen styles. It is an app launcher: it opens CoupleDraw with My art selected, and iOS may ask you to unlock first. Tap Draw to edit. It does not display the latest drawing or change the system wallpaper.

After installing the updated app, press and hold the Lock Screen, tap **Customize → Lock Screen → Add Widgets**, find **CoupleDraw**, add **Open CoupleDraw**, then tap **Done**. If it is missing, check that the widget target built, is embedded under the main app target's **Embed App Extensions** phase, and uses the same signing Team and an identifier prefixed by the app's identifier.

The `.xcodeproj` is already included. `tools/generate_xcodeproj.py` regenerates the Personal Team project if you add source files. Run `python3 tools/generate_xcodeproj.py --enable-push` only when signing with a team and profile that support Push Notifications; this adds APNs entitlements and the capability. `project.yml` is an optional XcodeGen alternative without Push enabled by default. The unsigned iPhoneOS Release build has been verified on a Mac; physical-device behavior still needs testing.

### Build an unsigned IPA on a Mac

Run `sh tools/build-unsigned-ipa-on-mac.sh` from the project directory. Install the **full Xcode app**, not only the standalone Command Line Tools. If macOS points at Command Line Tools but `/Applications/Xcode.app` exists, the script uses Xcode for this build without changing the system setting. If Xcode has another name or location, run `XCODE_APP_PATH="/path/to/Xcode.app" sh tools/build-unsigned-ipa-on-mac.sh`. The script builds the **iPhoneOS Release** target with signing disabled, checks that the Lock Screen widget was embedded, and creates `dist/CoupleDraw-unsigned.ipa`. A simulator build cannot be installed on an iPhone. The unsigned IPA is a package for later signing; it cannot be installed directly. Sign both the app and its embedded `PlugIns/CoupleDrawWidget.appex` with appropriate identifiers and provisioning profiles before installation. This script uses the project's default non-Push configuration for Personal Team compatibility.

GitHub Actions also runs this build on every push. Open the commit's **Build unsigned IPA** run in the **Actions** tab and download `CoupleDraw-unsigned.ipa` from its artifacts. You can also start a build with **Run workflow**. To publish a GitHub Release, tag a commit containing the workflow (`git tag v1.0.0` and `git push origin v1.0.0`). The tag build attaches the same unsigned IPA to the new Release. The repository must include the Xcode project, source files, assets, and build script for the workflow to succeed.

### Install on an iPhone

The IPA from **Releases** or **Actions** is unsigned. Download it only from this repository, then sign it with credentials and provisioning profiles that cover the iPhone. The app and its embedded widget have separate bundle identifiers, so each needs a matching profile. The default identifiers are `com.example.CoupleDraw` and `com.example.CoupleDraw.Widget`; use your own identifiers when signing. An ad-hoc signature without Apple provisioning does not make the IPA installable on a normal iPhone. Keep signing keys, `.p12` files, passwords, and profiles out of Git and GitHub Releases. [Apple's device distribution guide](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices) explains registered devices and provisioning.

**Build and sign in Xcode (simplest for your own phone):** Add your Apple Account in **Xcode → Settings → Accounts**. Open the project, select the CoupleDraw and CoupleDrawWidget targets, enable **Automatically manage signing**, select the same Team, and give them unique identifiers such as `com.yourname.CoupleDraw` and `com.yourname.CoupleDraw.Widget`. Connect and trust the iPhone, select it as the run destination, then use **Product → Run** (`⌘R`). Xcode signs and installs both targets. If iOS prompts for Developer Mode or to trust the developer, follow the on-device prompt. [Apple's Xcode device guide](https://developer.apple.com/documentation/xcode/building-and-running-an-app) covers this flow.

**Sign a Release IPA with zsign on a Mac:** Obtain a signing certificate with its private key (`.p12`) and two matching `.mobileprovision` files, one for the app and one for the widget. The profiles must include the target device for development or Ad Hoc distribution. The Release IPA uses example bundle IDs, so unpack it and change **both** IDs before signing. Install [zsign](https://github.com/zhlynn/zsign) and set `P12_PASSWORD` in your shell without storing it in the repository, then run:

```sh
mkdir signing-work
unzip -q CoupleDraw-unsigned.ipa -d signing-work
plutil -replace CFBundleIdentifier -string com.yourname.CoupleDraw signing-work/Payload/CoupleDraw.app/Info.plist
plutil -replace CFBundleIdentifier -string com.yourname.CoupleDraw.Widget signing-work/Payload/CoupleDraw.app/PlugIns/CoupleDrawWidget.appex/Info.plist
zsign -k certificate.p12 -p "$P12_PASSWORD" \
  -m app.mobileprovision -m widget.mobileprovision \
  -o CoupleDraw-signed.ipa signing-work/Payload/CoupleDraw.app
```

Check that the signed IPA still contains `PlugIns/CoupleDrawWidget.appex`, that both bundle IDs and embedded profiles match, and that the signing tool reports success for both targets. Install the signed IPA with Xcode's **Devices and Simulators** window, Apple Configurator, or a device installer that supports your provisioning type. [Apple documents installation of exported IPAs](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices).

**Sign on the phone with ESign:** Import the unsigned Release IPA, your own `.p12` certificate, and the app and widget provisioning profiles into ESign. Set the app identifier to your provisioned ID, keep the widget identifier under that app ID, and sign both bundles before installing. Check the resulting bundle IDs and embedded widget if ESign offers a preview. The exact ESign menus vary by version; use its current signing and install flow. Do not upload your private key or provisioning profiles to a public signing site. A signed IPA installs only while its certificate and profiles are valid and the device is allowed by the profiles. For an update that preserves local drawings, sign with the same Team and app identifier as the installed copy.

The local document uses PencilKit's editable `PKDrawing.dataRepresentation()`. `CanvasStore` saves a separate JSON record for each canvas, and Apply stores a document snapshot, PNG, and revision entry. A resized JPEG and normalized photo placement are kept as a separate background layer so you can reframe it later; photos are limited to 900 KB before sync. The main screen previews saved strokes; drawing happens in the full-screen editor. Undo and redo apply to the current editor session. The lasso keeps its tool instance during drawing updates, and the canvas supplies an empty keyboard view so selecting strokes does not raise the software keyboard. Partner's target defaults to this phone for testing; enter the partner phone's portrait pixel dimensions with **Partner's art → Preview size** to preview that destination. The selected Shortcut result is rendered for the receiving iPhone. iOS may still zoom or reframe wallpaper in its composer. Install upgrades over the existing app with the same Bundle ID; deleting it removes local documents unless backed up.

Apply shows a small banner at the top for a few seconds without blocking the screen. To share an exported wallpaper manually, open **History** and tap the share icon next to its revision. **History → Delete all** asks for confirmation and removes saved revisions and exported PNGs for the open canvas on this phone. It leaves the editable drawing and the paired server copy intact; Apply again before using that source in the wallpaper Shortcut.

The canvas and wallpaper export use a fixed PencilKit light appearance regardless of each phone's system setting. White ink on a black background remains white for both partners and in the exported wallpaper. Install this update on both phones for matching previews; saved drawings remain editable.

## Pair two phones

The included `server/coupledraw_server.py` uses only the Python standard library and SQLite. It is **not deployed for you**. You need one reachable server and a token for each phone; there is no external database or account service. For two phones on the **same Wi-Fi as your Mac**, `cd` into this repository in Terminal, then run:

```sh
python3 server/coupledraw_server.py create-pair --db coupledraw.sqlite3
python3 server/coupledraw_server.py serve --db coupledraw.sqlite3 --host 0.0.0.0
```

Run `create-pair` only once for a new pair; save its private **A** and **B** tokens before closing the Terminal. Keep the server Terminal open. Find your Mac's Wi-Fi IP in **System Settings → Wi-Fi → Details → IP Address**. On **both iPhones**, open Pair and enter `http://MAC_IP:8787` (for example `http://192.168.1.20:8787`), with no `/v1/state` path. Give person A only token A and person B only token B. Allow **Local Network** access when iOS asks. The Mac must remain awake and permit incoming connections to Python if its firewall asks. Use your Mac's LAN IP, not `127.0.0.1` or `localhost`, which refer to the iPhone itself when entered there. If it cannot connect, check that both phones are on the same Wi-Fi, not an isolated guest network, and that the Mac IP has not changed. HTTP sends the token and drawings without encryption, so use it only on a trusted local network; do not port-forward port 8787 to the Internet.

To choose memorable strings instead of generated tokens, run `python3 server/coupledraw_server.py create-pair --custom-tokens --db coupledraw.sqlite3`. The server privately prompts for **two different tokens**, one for A and one for B, with confirmation. Use 20–100 letters, digits, or `._~-` characters without spaces. Choose hard-to-guess passphrases, ideally generated random words rather than names or dates. The chosen strings are not echoed or printed, so keep them in a password manager. Do not put tokens directly in command arguments, which can be recorded in shell history. This creates a new pair; it does not change credentials for an existing pair. Both phones must connect using the new A/B strings.

For **Tailscale testing**, connect the Mac and both iPhones to the same tailnet. Run the server with `--host 0.0.0.0` as above and enter `http://MAC_TAILSCALE_IP:8787` in Pair on each phone, for example `http://100.111.112.50:8787` if that address belongs to the **Mac**. Paste the A or B token into the second field; the URL alone is not enough. Tailscale assigns addresses in `100.64.0.0/10`, and this app accepts HTTP to that range for testing. Tailscale encrypts traffic between tailnet devices; do not assume a `100.x` address belongs to your tailnet without checking it in Tailscale. If Pair cannot reach the Mac, check that Tailscale is connected on all three devices and that the Mac firewall permits the server. Do not expose port 8787 with Tailscale Funnel or public port forwarding.

If the partner is **outside your Wi-Fi**, stop the LAN server and run it with its default loopback binding instead:

```sh
python3 server/coupledraw_server.py serve --db coupledraw.sqlite3
```

In another Terminal, install Cloudflare's tunnel client once and start a temporary HTTPS tunnel:

```sh
brew install cloudflared
cloudflared tunnel --url http://127.0.0.1:8787
```

Copy the generated `https://….trycloudflare.com` address, without `/v1/state`, into **Pair** on both phones. The Mac must remain awake and both Terminal processes running; the temporary URL can change on restart, in which case reconnect both phones to the new URL with the same tokens. The app accepts HTTP only for loopback, private IPv4, Tailscale's `100.64.0.0/10` range, or `.local` hosts; use HTTPS for all other addresses. For a stable always-on service, host the Python process on a server and use a permanent HTTPS reverse proxy or named tunnel. Keep the internal HTTP port bound to `127.0.0.1` for tunnel use. Tokens are stored in iOS Keychain; the server stores only their SHA-256 hashes. Protect the printed tokens and the server database. There is no self-service token rotation in this prototype; APNs alerts require separate setup below.

### Ubuntu VPS

Copy the **complete** `server/coupledraw_server.py` to the VPS, for example as `~/coupledraw/coupledraw_server.py`. Replace the VPS script and restart it whenever upgrading the app, keeping the existing SQLite database and A/B tokens. An older server can drop newer data; the app reports an upgrade error if it lacks the whiteboard protocol. From `~/coupledraw`, check the script and create the pair once:

```sh
python3 -m py_compile coupledraw_server.py
python3 coupledraw_server.py create-pair --custom-tokens --db coupledraw.sqlite3
python3 coupledraw_server.py serve --db coupledraw.sqlite3
```

Save the A/B tokens privately. The server binds to `127.0.0.1:8787` by default. For a persistent process, create a systemd unit at `/etc/systemd/system/coupledraw.service` (replace `YOUR_USER` and the paths with your VPS account):

```ini
[Unit]
Description=CoupleDraw paired server
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

Stop the foreground `serve` process before starting the service. Run `sudo systemctl daemon-reload`, `sudo systemctl enable --now coupledraw`, and `sudo systemctl status coupledraw` to check it. To follow logs, run `journalctl -u coupledraw -f`. Set a DNS A record for your domain to the VPS, install an HTTPS reverse proxy such as Caddy, and forward public ports 80/443 to the loopback service:

```caddyfile
draw.example.com {
    reverse_proxy 127.0.0.1:8787
}
```

Enter `https://draw.example.com` and each person's own token in Pair. Test one phone's Apply, then open the other phone and confirm that it receives the revision. Keep port 8787 private. For a private Tailscale deployment without a domain, bind to **the VPS's** Tailscale IP with `--host VPS_TAILSCALE_IP`; both phones must join that tailnet and use `http://VPS_TAILSCALE_IP:8787`. Never publish that HTTP port to the open Internet. Back up the SQLite database, which contains the paired roles and drawings. For notifications while the app is closed, continue with the optional ntfy or APNs setup below.

Each HTTP response logs its UTC timestamp, authenticated `client=A` or `client=B` (`-` for invalid or missing credentials), method, endpoint, status, and `duration_ms`. A successful Apply also logs the source and revision. For example: `2026-09-29T14:22:11.971+00:00 client=A peer=127.0.0.1 POST /v1/apply status=200 duration_ms=0.7 source=a revision=1`. The duration ends when the response starts; ntfy/APNs delivery runs separately. `peer=127.0.0.1` is expected behind a local reverse proxy and does not identify the phone; the authenticated A/B role does. Tokens, drawing data, and URL query strings are not logged. Foreground long-poll requests appear about every 20 seconds per connected phone when nothing changes; Apply or a shared stroke operation wakes a waiting request immediately. The app shows “live while open” in its sync status after a successful waiting request; “checking every 30s” means the VPS has not provided the long-poll response header. The server log includes `prefer_wait` and `waited_ms` for each GET /v1/state so you can verify the proxy forwards the waiting request. If a proxy closes 20-second requests early, the app retries with a 10-second wait. Unchanged requests return HTTP 304 with no drawing or photo bytes. Upgrade the server and both apps together: this app reports an upgrade error if the server lacks the whiteboard protocol. The duration of a waiting response includes its time waiting for a change.

### Partner Apply push alerts

With a Personal Team, the receiving phone can show a **local notification while CoupleDraw is open** after its foreground waiting request detects the other person's Apply. This requires notification permission but no Push entitlement. For alerts while CoupleDraw is closed, the VPS can publish to the separate **ntfy** app; alternatively, a Push-capable team can use direct APNs. The direct APNs path registers one current iPhone per role and skips alerts if no recipient device is registered. All alerts describe a committed revision; none sets wallpaper by itself. Delivery can be delayed or omitted by iOS.

#### ntfy on a Personal Team

The public [ntfy iPhone app](https://docs.ntfy.sh/subscribe/phone/) can receive a notification while CoupleDraw is closed without adding Push Notifications to **CoupleDraw's** provisioning profile. From the directory containing the database, configure the ntfy server once:

```sh
python3 coupledraw_server.py configure-ntfy --db coupledraw.sqlite3
python3 coupledraw_server.py serve --db coupledraw.sqlite3
```

At the prompt, press Enter for `https://ntfy.sh`, or enter your own ntfy HTTPS server base URL. This is the **base URL**, without a topic path: `https://ntfy.sh/custompath` is a full publish URL where `custompath` is a topic. The server saves the base URL in the SQLite database, generates a distinct private topic for each phone, and publishes to `base URL/topic` with an HTTP POST (the equivalent of `curl -d "message" https://ntfy.sh/custompath`). Restart a running server after changing the setting. `NTFY_BASE_URL` remains an optional environment override, including for systemd. The VPS must be able to make outbound HTTPS requests to the selected ntfy server. The pairing server remains private behind your HTTPS reverse proxy or Tailscale; this setting only controls the outbound alert service.

On each iPhone, update CoupleDraw and reconnect to the VPS. In **Pair → Alerts through ntfy**, copy **that phone's** topic. Install the [ntfy app](https://docs.ntfy.sh/subscribe/phone/), allow its notifications, and subscribe to that exact topic on `https://ntfy.sh`. The two phones have **different randomly generated topics**. After A taps Apply, only B's topic gets the generic alert, and vice versa. You can test topic delivery by publishing a generic test message to your own topic from the VPS, but do not put drawing data or pairing tokens in messages. On iOS 27, set Shortcuts **Notification → App: ntfy → Title: CoupleDraw wallpaper ready**, then **Get My CoupleDraw Wallpaper → Set Wallpaper**. After upgrading the app, open it once while unlocked to migrate the pairing token for locked-device Shortcut access. Unlock once after each reboot. Test whether iOS permits this automation to run while locked without confirmation.

On public ntfy.sh, anyone who knows a topic can subscribe or publish to it, so treat each topic like a password. The generated topics are long and random, and the alert contains no drawing or pairing token. ntfy.sh handles the iPhone notification; delivery timing and the Shortcuts wallpaper action still depend on iOS. If the receiving phone is open, CoupleDraw suppresses its own local alert when ntfy is configured to avoid a duplicate.

#### Direct APNs with a Push-capable team

1. For **remote push**, use an Apple Developer Program team that supports Push Notifications. Enable Push for your app's exact Bundle Identifier, create an APNs authentication key (`.p8`), and regenerate with `python3 tools/generate_xcodeproj.py --enable-push`. The final installed IPA needs a matching `aps-environment` entitlement; Debug uses development and Release uses production. A Personal Team cannot create this profile, even when installing only on your own device. Do **not** put the `.p8` key in the project ZIP or the app.
2. On the VPS, install the optional server dependencies: `python3 -m pip install -r server/requirements-push.txt` (or install `httpx[http2]` and `cryptography` if using only the standalone Python script). Set `APNS_KEY_FILE` to the private `.p8` path, `APNS_KEY_ID` to its Key ID, `APNS_TEAM_ID` to your Team ID, and `APNS_TOPIC` to the app's final Bundle Identifier. Supply these variables in the server's systemd environment and restart it. Keep the key readable only by the service account. The server validates APNs setup at startup when all four variables are set.
3. Install the updated signed app on both iPhones. Pair each phone with its own A/B token, allow the notification permission prompt, and check **Pair → Partner alerts**. On Personal Team, tap **Enable alerts while app is open** if you had paired before upgrading; leave the receiving app open while testing. For remote push, both devices need to register; the server's `/v1/state` response reports `pushConfigured` for diagnosis. Test by tapping Apply on one phone and observing the other.
4. On iOS 27, in Shortcuts create an automation with **Notification → App: CoupleDraw → Title: CoupleDraw wallpaper ready**. Add **Get My CoupleDraw Wallpaper → Set Wallpaper** for Lock Screen. Choose the source under **My Lock Screen shows** in the receiving app. Check whether **Allow Running When Locked** is offered for this automation, turn off **Show Preview** in Set Wallpaper if available, and test on the actual phone. Apple's current guide lists the Notification trigger, but does not list it among the triggers guaranteed to run without asking; wallpaper confirmation is still system controlled.

APNs uses an HTTP/2 TLS connection from the VPS to Apple. The Python server keeps device tokens in SQLite and signs short-lived provider JWTs from the `.p8` key. If APNs rejects a push, the server prints the rejection reason without printing the device token. A notification is sent asynchronously after Apply, so a successful Apply response means the drawing was stored; check the server log for APNs acceptance. When changing the paired server, re-enable alerts so the new server receives this phone's device token.

Each phone maps My art to its own server canvas, Partner's art to the other person's canvas, and Our art to the shared canvas. Both people can draw, lasso/move, erase and clear strokes on Our art, regardless of who drew them. Updates are sent after each completed gesture, with a 150 ms batching window; this build does not stream the unfinished pen tip or show partner cursors. Incoming edits wait until your current gesture ends so PencilKit does not reset under your finger. The server sends stroke deltas; idle requests carry no drawing bytes.

Queued edits are stored on the phone, scoped to its server/token, and retried with stable operation IDs. Independent concurrent strokes merge. If two people edit the same stroke, the first server commit wins: the other phone saves its version under **History → Recovered draft**, then refreshes the shared board. Recovery copies do not replace the wallpaper returned by Shortcuts. Their images can be shared from History. Clear removes only strokes visible when you tap it, preserving strokes the other phone adds concurrently. A very large board is capped at 3,000 strokes or 3 MB of stroke archives; Apply it to History, then clear it to start a new board.

**Apply** first flushes your queued strokes and fetches the latest board. The server checks the board and saved revision numbers atomically; if a partner changed the board meanwhile, the app refreshes and retries up to three times. A successful shared Apply saves an immutable snapshot that both phones can retrieve. Each phone renders at its own wallpaper dimensions. Background photo/color changes are shared on Apply, while stroke edits sync before Apply. Choose **Our art** under **My Lock Screen shows** on both phones if both should use that saved image. The wallpaper still changes through your Shortcut.

Upgrade both apps over their existing installations and restart the VPS script with the same SQLite database and A/B tokens. Existing server base art and both per-person layers migrate once into editable shared strokes. Previous local layers are preserved as recovery History. Once migrated, old clients cannot upload their old layers; update both phones. Locked or suspended phones catch up when opened or when their Shortcut runs. In Pair, **Replace … with server copy** replaces a personal canvas; whiteboard queues are preserved.

The Shortcut checks the service once when invoked and returns the latest selected source, even if the main app was closed. Partner's art requires pairing and a partner Apply. On iOS 27, the new Notification automation trigger may run the receiving phone's Shortcut in response to the APNs alert, but this is not physically verified, and iOS may require confirmation. A scheduled Shortcut automation may check at its scheduled time, but it can reapply the same image; the iOS wallpaper action's confirmation and timing are system controlled. A waiting HTTP connection only runs as long as iOS grants execution time. The optional **Experiment: background location sync** switch in Wallpaper setup first requests While Using permission and starts a location session. With that permission iOS shows a prominent background location indicator. Requesting Always is a separate optional step that iOS may defer; with Always the app requests that the prominent indicator be hidden, but system privacy icons and alerts may still appear. It ignores coordinates, can use substantial battery, and does not guarantee execution or set wallpaper. Turn it off after testing.

## Wallpaper feasibility and proposed production flow

Apple documents the **Set Wallpaper** action in Shortcuts and device-specific personal automations. An installed app can expose App Intents to Shortcuts, but an App Intent does not give the app a public wallpaper-setting API or a remote trigger for the other person's phone. Apple's background notification documentation explicitly says delivery is not guaranteed. Therefore the specification's immediate `partner Apply → other locked iPhone wallpaper changes` is **unverified and must not be promised**. A remote push can announce the revision; it cannot be treated as a guaranteed Set Wallpaper trigger.

This build exposes **Get My CoupleDraw Wallpaper** as an App Intent allowed to run while locked. The pairing token is stored with After First Unlock protection, so a Shortcut can authenticate to the VPS after one unlock since the last restart. A Shortcut on the receiving phone passes its returned image to **Set Wallpaper** for that phone's Lock Screen. If Set Wallpaper has a **Show Preview** option, disable it and test on the actual iOS version. If iOS still presents a Save/confirmation screen, a personal automation does not remove that prompt. The included service has authenticated snapshots and optional ntfy or APNs alerts when configured, but no hosted endpoint or verified automatic wallpaper behavior. A notification tap can provide a user-assisted flow if automation does not run.

Useful primary sources:

- [Apple Shortcuts: setting triggers, including app opened](https://support.apple.com/guide/shortcuts/setting-triggers-apde31e9638b/ios)
- [Apple Shortcuts: personal automations](https://support.apple.com/guide/shortcuts/intro-to-personal-automation-apd690170742/ios)
- [Apple: Set Wallpaper action in an automation](https://support.apple.com/en-ke/guide/ipod-touch/iph3d267104/ios)
- [Apple Developer: App Intent](https://developer.apple.com/documentation/appintents/appintent)
- [Apple Developer: background pushes are not guaranteed](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)
- [Apple Developer: background location updates](https://developer.apple.com/documentation/corelocation/handling-location-updates-in-the-background)
- [Apple Shortcuts: Notification trigger](https://support.apple.com/guide/shortcuts/apd932ff833f/ios)
- [Apple Developer: register with APNs](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns)
- [Apple Developer: send notification requests to APNs](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns)

## Next implementation gates

1. On two physical iPhones, verify Shortcuts' Get Contents of URL → Set Wallpaper with a private test endpoint. Record whether the action targets only the designated Lock Screen, asks for confirmation, and works when invoked from local automations. The actual iOS 27 behavior is **not physically tested** here.
2. Test the included Python/SQLite service on a reachable HTTPS host with two phones, including disconnect and reconnect, token rejection, revision conflicts, and backup restoration.
3. Replace PencilKit's opaque document as the collaboration source with author-attributed operation objects and immutable snapshots. Define deterministic handling for background and layer reorder operations, idempotent operation IDs, an offline queue, and conflict tests. PencilKit alone cannot meet the spec's per-stroke author and operation sync requirements.
4. Register each receiving device with pixel dimensions and its own canvas ID. Render **that device's** canvas, not the sender's local screen size. Publish it via a revocable HTTPS token; return the latest immutable revision with `Cache-Control: no-store` and avoid logging tokens. Never put tokens in public documents or analytics.
5. Configure the included APNs path with real signing credentials, add a local Shortcut setup flow and a test button, and test all foreground/background/locked/terminated/force-quit/offline cases on real devices. Document observed prompts and delays.
6. Add structured layers, selection, shapes, editable text and images, fine eraser, operation-based undo, and performance checkpoints. These features are **not** implemented in this prototype.

## Status by scenario

| Scenario | Status in this repository |
| --- | --- |
| Draw and save My art and Our art; view Partner's art | Implemented as separate local documents, with server ownership checks when paired |
| Apply and export a target-sized wallpaper PNG | Implemented; Shortcut output uses local iPhone dimensions |
| Choose own, partner, or together for this phone | Implemented locally per phone |
| Paired snapshots after Apply | Included server and foreground long polling; same-Wi-Fi HTTP or your own reachable HTTPS deployment, pending physical-device verification |
| Partner Apply alert while app is open | Local notification after foreground update; works without Push entitlement, pending physical-device verification |
| Partner Apply alert while app is closed | ntfy route works with Personal Team after setup; direct APNs route requires a Push-capable team. Both need physical-device verification |
| Local Shortcuts action returns selected last applied PNG | Implemented; Set Wallpaper setup requires the user |
| Manually set the exported wallpaper | User action in iOS |
| Live Our art | Shared stroke edits, move/erase/clear, operation-aware undo, persistent offline queue, delta long polling and version-checked Apply; physical-device verification pending |
| Remote Apply automatically sets a locked phone's wallpaper | Unsupported as a product claim; no physical test |
| Experimental background location polling | Optional; not guaranteed or device-tested |

No hosted server, APNs key, Apple Developer signing identity, or Shortcut is supplied. The unsigned IPA is built locally or by GitHub Actions and still requires your signing credentials and device provisioning. There is no private API path in this repository.


## Verify this update

Server tests (standard library only):

```sh
python3 -m unittest discover -s server -v
```

The integration tests cover simultaneous A/B additions, edit retries, moving/erasing a partner stroke, overlapping-edit rejection, clear during a concurrent addition, migration races, cross-process long-poll wakeups, restart persistence, malformed input and version-checked Apply. They use opaque test archives; Pillow/PencilKit rendering is not available in Linux.

In Xcode, select **Product → Test** to run the PencilKit model tests, including serialization matching, a partner update arriving during a gesture, queue restoration, move/undo and different phone heights. Xcode compilation and camera/PencilKit behavior still need testing on a Mac and two iPhones.

On two updated phones, open Our art, draw simultaneously, move/erase the other's stroke, briefly disconnect one phone and reconnect, then Apply. Check History on both and run the Shortcut with Our art selected. For Camera, test permission allow/deny, cancel, front/rear capture and reopening the framing editor. Check that the capture stays framed when the camera dismisses. Camera is unavailable in the simulator; Photos and Files remain usable.
