# Pairing with a code

[Back to README](../README.md)

## Create and join

1. Open **Pair** on the first phone. The server defaults to `https://draw.huythedev.com`. To self-host, type your HTTPS server address; a bare hostname automatically uses HTTPS. Private-network HTTP is also supported for local testing.
2. Tap **Create Pair**. Share the displayed six-digit code, use **Share invite**, or show the QR code to your partner. Keep this temporary invitation private.
3. On the second phone, tap **Join Pair** and enter the code on the same server. Opening the shared `coupledraw://pair` link fills the server and code; verify the displayed server, then tap Join Pair. The QR code contains the same invitation link.
4. Both phones connect automatically. Each receives a different private credential, saved in its Keychain; there is no A/B token to copy.

Codes expire after five minutes. Joining consumes a code immediately; another phone cannot use it to join that pair. The server creates the permanent pair only on a successful Join, so abandoned invitations do not create permanent member accounts. **Cancel invite** invalidates a pending code. Once someone has joined, finish connecting to keep access to the pair.

Six digits identify an invitation on one server. They cannot locate a custom VPS globally: when entering a code manually, both phones need the same server. Share an invite link or QR code to carry a custom server address automatically. Opening a link only fills fields; it never silently replaces an existing pair or sends its credential to the link's server.

## Interrupted connections

Each phone saves a random private recovery secret in its Keychain **before** sending a Create or Join request. Reopen **Pair** to resume if the app closes or a response is lost. A creator waits using a 20-second request that wakes when the partner joins, only while this screen is open and the app is active.

After a Join, the same private recovery secret can retrieve that phone's credential for up to 24 hours. This is a private retry, not a reuse of the invitation code. The other phone's credential is never returned. If connecting fails, tap **Retry connecting**; the existing configured pair remains available until the new connection succeeds. Once setup completes, the temporary recovery secret is removed from the phone. Long-lived credentials continue working after recovery metadata is purged.

If a pending invitation expires, cancel it and create a new code. If a joined phone never completes recovery within 24 hours and did not save its credential, create a new pair together. Reinstalling the app or switching signing identities can also lose access to Keychain data; keep the same app identity when updating.

## Existing pairs and server upgrades

Existing server-created A/B tokens continue to work under **Manual pairing with an existing token**. Update the **complete** Python server script and restart it while keeping its SQLite database and media directory. New pairing tables are created automatically; existing artwork, member hashes, ntfy topics and credentials are preserved. You no longer need to run `create-pair` for new pairs.

Configure ntfy separately as described in [server setup](server.md). Code pairing does not change wallpaper automation or start background polling. Each phone still subscribes to its own private ntfy topic if using closed-app alerts.

## API and security details

All pairing operations use JSON POST requests without an existing bearer token. They never put a private recovery secret in a URL. Use TLS on public servers and serve these paths directly; the app rejects redirects.

| Endpoint | Request | Result |
| --- | --- | --- |
| `/v1/pairing/create` | `secret`: 64 lowercase hex characters from 32 random bytes | `state: waiting`, six-digit `code`, Unix-seconds `expiresAt` |
| `/v1/pairing/join` | `secret`: a different phone's random secret; `code`: six ASCII digits | `state: paired`, `role: B`, private `credential` |
| `/v1/pairing/status` | Creator's `secret`; optional `Prefer: wait=20` | Waiting invitation, or `state: paired`, `role: A`, private `credential` |
| `/v1/pairing/cancel` | That phone's `secret` | `state: cancelled` for a pending/expired invitation; HTTP 409 after a successful Join |

Create and Join retries with the same private secret are idempotent while recovery is retained. An expired or already-consumed code with a new secret returns HTTP 410. Invalid requests return 400; bounded attempt/resource limits return 429 with `Retry-After`. Codes, secrets, credentials and invitation query strings are omitted from logs.

SQLite uses an immediate transaction to consume the code and create both member rows together, including across multiple server processes. Credentials are HMAC-SHA256 outputs with each phone's 256-bit secret as the key and a random pair ID plus role as the message. The database stores hashes of credentials and recovery secrets, rather than their plaintext. Temporary codes and recovery metadata are purged on subsequent pairing requests; the bounded retained session count limits abandoned invitations. Treat the database and backups as private.
