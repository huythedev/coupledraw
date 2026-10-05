# Images and privacy

[Back to README](../README.md)

CoupleDraw uses the server as temporary delivery storage for background photos and sticker images. Both phones keep originals for the latest paired My art, Partner's art, and Our art. They also keep images used by local drafts and saved History. You do not need a permanent image archive on the VPS.

## Delivery and deletion

1. Apply uploads a saved drawing and its image layers through the authenticated pairing API.
2. The server writes private image files and keeps drawing metadata, image hashes, and placement in SQLite. A pending original stays available while either phone has not confirmed it.
3. Each updated phone saves the originals to disk, protects them from cache cleanup, and confirms the exact canvas revision and hashes. A failed download, render, or local write does not send a receipt. An image skipped by a dirty draft still gets a protected local copy.
4. Once both phones have confirmed every latest reference to an image, the server deletes its file. Downloads, ntfy alerts, and known-version hints are not receipts. A delayed receipt cannot delete a newer revision.

Identical images share a file. If another canvas or pair still awaits that image, its file remains until those deliveries complete. Superseded images with no pending references are removed too. There is no expiry for an unread latest image: it waits for the offline phone rather than disappearing before delivery.

Open both apps after upgrading so they can receive and confirm existing originals. A Shortcut also saves and confirms newly received images when invoked. This does not add background polling or notifications. Pending receipt retries survive an app restart.

The Shortcut retains every latest original but only loads and exports the chosen wallpaper. It sends pending receipts after that export succeeds. The exported file remains available to Shortcuts even if Clear cache runs during the handoff.

## Phone storage and Clear cache

Each phone stores the latest originals for all three paired canvases so it can render wallpapers and help its partner recover a lost copy. It does not download the other phone's entire History. Locally saved History can retain older originals until you delete those revisions.

**Setup → Clear cache** removes rendered wallpaper PNGs and unused originals. It preserves current drafts, History, and the latest relay originals, including photos kept while a dirty draft stayed unchanged. Missing PNGs regenerate locally. When a newer applied canvas stops using an image, its old relay reference is released; Clear cache can remove it once no draft or History needs it.

Keep the same bundle ID and signing Team when installing updates to preserve app documents. Removing the app or losing the phone's local storage can remove originals.

## Recover a missing image

A phone missing a delivered original asks the server to queue a resend. Open CoupleDraw on the other phone: its normal foreground sync sees the request and uploads the matching local original. The receiving phone then saves and confirms it again, and the server deletes the temporary resend. Neither the resend request nor the upload sends an extra notification.

Recovery requires a reachable partner phone that still has the image. If both phones lost it, the server cannot restore it after deletion; import the original again and Apply. You still need valid pairing credentials to request recovery. The wallpaper action reports missing media instead of silently producing a cropped or incomplete image. Shortcut invocations skip donor uploads to keep retrieval quick; open the donor app for automatic resends.

## What stays on the server

Only photo/sticker file retention changes. SQLite still stores latest drawing archives, whiteboard strokes, image placement and hashes, revision numbers, credential hashes, and configured alert destinations. The server renders no wallpaper PNG. This is not a delete-everything or end-to-end encrypted design: the server operator can read queued images and stored drawing data. Use HTTPS outside trusted local testing.

Replace the complete Python script and update both phone apps together; older clients cannot confirm durable storage, so their originals remain queued. Keep the database and private media directory when upgrading. See [server setup](server.md) for migration, compacting, and backups. Backups taken before delivery may still contain an image even after its live server file is deleted. Deleting a file is not a guarantee of secure physical erasure on the VPS.
