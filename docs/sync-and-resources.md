# Sync, storage and resource limits

[Back to README](../README.md) · [Development](development.md)

## SQLite and long polling

The server uses bounded worker threads and a separate SQLite connection for each transaction. Schema migration and WAL setup happen at startup. Normal state reads use `query_only=ON` and `BEGIN`, so ETag checks do not reserve the WAL writer lock. The first request for a pair can initialize its legacy shared base or register a client's history capability; those one-time writes still need a writer transaction.

Idle long polls read only revision metadata. A process-local condition is leased per pair, so an Apply or stroke edit wakes that pair's waiting clients. The lease is removed when the last waiter exits. A generation check prevents a change between reading state and waiting from being missed. Multiple server processes still discover each other's changes through a metadata recheck at most one second later. Connections close between rechecks; the server keeps no SQLite transaction or media lock while waiting.

Media hydration takes a shared filesystem `flock` **before** opening its read snapshot. File writes and pruning take the exclusive lock **before** their SQLite write transaction. This order prevents a photo from disappearing between reading its metadata and loading its bytes, including across server processes. The response is fully copied into memory; normal socket writes happen after these locks are released. The media lock is released by closing its descriptor, including if the process terminates. Use a local filesystem with working SQLite and POSIX locking semantics.

Long polls are capped at 25 seconds, sockets at 45 seconds, and worker connections at 64. A disconnected long-poll client may retain its worker until the bounded wait ends. Overload and SQLite busy responses return HTTP 503 with `Retry-After`. These bounds are not a high-scale asynchronous server; benchmark before increasing the number of connected phones.

## Safe whiteboard history cleanup

Active art remains limited to 3,000 strokes or 3 MB of stroke archives. Deleted strokes and operation digests have separate bounds: 6,000 tombstones, 4,096 operation digests, and a 1,024-revision window. The tighter boundary advances a per-pair `minimumRevision` checkpoint. Records at or below that checkpoint are removed; active strokes remain. Equal-revision records can be removed as a group, so the remaining counts may be below those limits.

Cleanup starts only after **both phones** advertise history protocol 1. Every new queued operation captures its base revision when enqueued and keeps it on retry. Recent operation IDs remain idempotent. An operation whose digest has been cleaned up cannot replay against an older base revision: the server returns HTTP 409 and the current full board. The app saves a recovered draft in History before dropping that stale queue and refreshing. Clients requesting a delta from before the checkpoint receive the full active board instead.

Legacy clients lack captured revisions, so their pairs retain history until both phones support cleanup. Reconnecting with an older client revokes that phone's permission, stopping further cleanup. A current app's legacy queued patches take the History recovery path after a checkpoint. An older app without checkpoint support receives an update error for editing that board; other canvases still work. Previously compacted history cannot be recovered by a downgrade. Server and app upgrades can otherwise happen independently; see [compatibility](compatibility.md). Deleted SQLite rows free pages for reuse; `compact-media` can also reclaim database space during maintenance.

## Shortcut memory use

The wallpaper action uses a lightweight store that opens the selected canvas, skips the History array and live whiteboard, and requests only the selected snapshot's vector data. Original image layers for all latest paired canvases are still retained locally, so both phones can recover delivered media. Other canvases are not rendered during a Shortcut.

The latest applied revision has a small per-canvas index. Old History is scanned one JSON object at a time if the index is missing or stale; recovery drafts and unrelated media are skipped. New Shortcut revisions go into durable individual journals and are merged into History by the main app, including before writes from an already open store. Cache cleanup preserves those journals and their originals.

Exports use the receiving iPhone's native portrait size. A matching cached PNG can be copied without decoding a bitmap. Otherwise rendering uses standard color range, bounded image downsampling, per-layer autorelease pools and direct ImageIO encoding to a file. Shortcut rendering bypasses the image cache. `IntentFile(fileURL:)` avoids constructing another complete PNG `Data` buffer. Export files survive Clear cache for Shortcuts to consume and are cleaned after a day on subsequent runs. Receipts are sent only after the selected export succeeds.

The renderer rejects non-finite dimensions, oversized design coordinates and output above 6 million pixels; the old 50-million-pixel maximum is no longer accepted. This is an allocation limit, **not a guarantee of a 30–50 MB total process footprint**. PencilKit, decoded photos, vectors and iOS add memory of their own; jetsam thresholds vary. Profile the Shortcut on real devices with long History, photo backgrounds and the maximum sticker count before claiming a memory budget.

## Retry policy

State, whiteboard and media receipt failures have independent exponential backoff with equal jitter, growing from 0.5–1 second to 30–60 seconds. Success resets the relevant schedule. HTTP 429/503 `Retry-After` values accept seconds or an HTTP date and form a lower bound, with additional jitter to spread reconnects. Server hints are persisted by origin and credential digest so a fresh Shortcut invocation also waits. Credentials are not stored in that retry record.

Whiteboard retries keep their original operation ID and base revision. Failed receipts remain pending on disk and never authorize deletion early. Long polling remains immediate on a healthy server; older servers fall back to a roughly 30-second check. Only an idle-connection timeout or connection loss shortens a 20-second poll to 10 seconds. Rate limits do not force that change. Suspension cancels foreground tasks; this adds no background location or continuous background requests.

## App sandbox and future extensions

There is **no App Group entitlement** in this project. Storage lives in the main app's `Documents/CoupleDraw`, centralized through `CoupleDrawStorage.root`. `LatestWallpaperIntent` is compiled into the main app target and can use that sandbox. The current Lock Screen widget opens the app; it does not read the canvases.

The file lock coordinates callers that can access the same root. It does not grant another sandbox access. Moving the wallpaper or editing logic into an independent extension requires an explicitly provisioned App Group, a migration to its container, matching entitlements and a review of Keychain access and data protection. Adding those capabilities now would change signing requirements without helping the existing launcher widget.
