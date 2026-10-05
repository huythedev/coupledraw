# App and server compatibility

[Back to README](../README.md) · [Server setup](server.md)

App builds and server builds do **not** need to match. Upgrade either side first; keep the existing server URL, pair and credentials. Compatibility is decided per feature and wire protocol, never by an exact release/build number.

| Combination | Behavior |
| --- | --- |
| New app, server without whiteboard support | Own/partner wallpaper sync and Apply continue. Older shared snapshots remain editable and publish through Apply. Servers with `/v1/draft` retain separate live drawing layers. |
| Old v1 app, new server | Existing v1 response fields, Apply, board operations and inline media remain supported. Media relay is used only when requested. |
| Future server listing protocols 1 and 2 | This app selects protocol 1; unknown features are ignored. |
| Feature absent on server or known partner | The attempted feature shows **Update needed**, naming the server or phone to update. Other canvases continue syncing. |
| Server supports only a newer feature protocol | That feature asks to update this app. Incompatible board payloads are skipped while compatible wallpaper items are decoded. |

Discovery travels in the existing state request, adding no recurring requests. The app advertises `X-CoupleDraw-API: 1` and `X-CoupleDraw-Protocols`, a small JSON map of feature names to supported version arrays. Servers predating those headers simply ignore them. `GET /v1/capabilities` also exposes the server's supported versions without credentials or artwork. Authenticated state includes `capabilities.apiVersions`, `protocols`, `peerProtocols` and `whiteboardReady`. Only two capability records are stored per pair; unchanged declarations do not need a write transaction. Missing discovery on an older phone means **unknown**, not unsupported: older header hints can prove support, but do not produce false update notices for absent declarations.

Photos, stickers, shared drawing, pairing and media transport have separate checks. A missing whiteboard protocol no longer fails the entire state request or Shortcut. The app can still draw locally and export previously applied wallpapers. A feature check happens when the user requests it, rather than repeatedly showing an update alert during long polling. Create/Join on an older server explains the update and keeps Manual pairing available. Very old servers without discovery are probed using the v1 endpoint; an unrecognized photo response keeps the local draft and displays the relevant update notice.

When a partner is known to use legacy shared drafts, a new app stays on that mode until both support the whiteboard. Initial migration waits for both declarations on servers supporting discovery. It never silently moves a legacy partner into a protocol they cannot edit. An already initialized board requires a whiteboard-capable app to edit it; other canvases remain available. Legacy callers of the existing board endpoints retain their original v1 behavior.

Temporary media delivery still requires exact durable receipts from **both** phones before deletion. An older inline-media client does not send those receipts, so its latest originals stay on the server. If a downgraded phone requests an original already delivered and deleted, the server requests donor recovery on its behalf and reopens that phone's receipt. Once a partner restores the image, the older phone receives inline bytes. Recovery requires an available original on a phone; erased media cannot be recreated by version negotiation.

Whiteboard cleanup permission is revoked when an older client reconnects. Previously removed history cannot be restored by downgrading: an unversioned edit against an already checkpointed board receives a feature-specific update error and the full board, while own/partner wallpaper syncing remains usable. Current apps with stale migrated queues retain a History recovery copy and refresh normally. Apps installed before this popup implementation show their existing error UI; a server update cannot add new UI to an old binary.

## Rules for future changes

- Keep `/v1` request and response semantics. Add optional fields; never rename/remove fields required by older decoders, reinterpret existing values, or make a new request field mandatory for unrelated actions.
- Advertise every supported protocol explicitly, such as `"whiteboard": [1, 2]`. A higher number alone does not imply support for version 1. Keep a v1 decoder/encoder and negotiate new formats separately.
- Keep the legacy endpoint or a faithful adapter while its old feature is supported. Do not perform irreversible pair migrations based on one phone's version alone.
- Use `code: "update_required"`, `feature` and `target` (`server`, `app` or `partner`) for unavailable features, with a readable `error` for older clients. Preserve existing conflict/HTTP behavior where old clients already handle it.
- Test new-app/old-server, old-app/new-server, mixed partners, unknown future fields, legacy retries, receipts and downgrade recovery before publishing. The Python and XCTest compatibility suites contain these regression cases.

These rules cover compatible v1 releases. Arbitrary third-party servers, removed APIs, unavailable originals and permanently compacted history cannot offer an unconditional compatibility guarantee.
