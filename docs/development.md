# Development and current scope

[Back to README](../README.md)

## Layout and checks

The iOS SwiftUI/PencilKit app is in [Sources](../Sources), the Lock Screen widget in [Widget](../Widget), and the Python/SQLite pairing service in [server](../server). The included `CoupleDraw.xcodeproj` is ready to open. If source membership changes, `python3 tools/generate_xcodeproj.py` regenerates the default Personal Team project. `project.yml` is an optional XcodeGen definition. Only regenerate with `--enable-push` if your team and provisioning support Push Notifications.

Run the server tests with:

```sh
python3 -m unittest discover -s server -v
```

In Xcode, choose **Product → Test** for the PencilKit model tests. The Python tests cover concurrent A/B updates, retries, move and erase, clear with concurrent additions, migration, long-poll wakeups, persistence, invalid input, and revision checks. Physical camera, PencilKit, signing, notification automation, and locked-device wallpaper behavior must be tested on actual phones.

## Data and syncing

Local canvases keep editable PencilKit data. Apply stores an immutable revision and a regenerable PNG cache; History also holds recovered drafts if a shared edit conflicts. Background photos and stickers are separate editable layers backed by content-addressed local image files, shared by all referencing documents. Legacy inline images migrate on loading. The Shortcut returns the latest selected applied revision at the receiving phone's native portrait dimensions and regenerates its PNG if cache was cleared.

Network JSON still transfers authenticated image data with changed snapshots. The server separates photo/sticker bytes into private content-addressed files and stores only references and placement in snapshot metadata. Old unreferenced media is reclaimed; current media stays available for offline phones. SQLite transactions protect media reads and pruning across server processes. The iOS app and Shortcut serialize local manifest writes and cache cleanup with a file lock. Cache clearing preserves documents and media referenced on disk, including updates made by another app process.

In Our art, completed stroke operations are batched briefly and sent to the paired service. The service returns deltas to active clients; idle long-poll responses carry no artwork. Offline edits are queued with stable operation IDs and retried. Independent strokes merge. A conflicting edit to the same stroke is saved as a recovered draft on the losing phone. Apply flushes local edits, checks current board/revision numbers, and publishes a snapshot. Background photo and color changes are shared on Apply. The board is capped at 3,000 strokes or 3 MB of stroke archives.

Foreground live updates require the app to remain active. A locked or suspended phone catches up when opened or when its Shortcut is invoked. There is no location-based background execution. Both phone apps and the server should be upgraded together for the shared whiteboard protocol.

## Robustness and security checks

Sync responses are ignored after a pairing change or foreground-session cancellation. Personal edits and shared background/sticker edits made while an Apply is uploading remain marked as unpublished. Remote snapshots are acknowledged only after rendering and local persistence succeed, so a failed render or disk write can be retried. Remote canvas writes report errors and restore the previous History manifest if the canvas write fails.

Authenticated requests use a dedicated ephemeral URL session and refuse HTTP redirects; Pair must contain the final server origin. Image decoding is capped at the same 2600-pixel limit as background imports, and the decoded image cache has count and memory limits. The wallpaper renderer rejects non-finite and out-of-range image dimensions before allocating a bitmap.

Regression tests cover delayed publish responses during re-pairing, editing during upload, retrying a failed render with the same ETag, failed canvas writes, bounded image decoding, malformed HTTP framing and extreme numeric headers/JSON, idle connection expiry, connection overload, and database file permissions. Existing drawing, sticker/paste, wallpaper rendering, media migration/pruning, and collaborative whiteboard tests remain in place.

## Practical limits

This is a self-hosted prototype. No hosted pairing service, Apple signing identity, APNs key, or pre-installed Shortcut is supplied. iOS controls wallpaper changes; there is no public direct setter in this app and no guaranteed remote wallpaper automation. Shared editing sends completed strokes, moves, and erases, but does not stream a partner's in-progress pen tip or cursor. Verify notification triggers and wallpaper prompts on the iOS version and devices you intend to use.
