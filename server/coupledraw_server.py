#!/usr/bin/env python3
"""Small private pairing/snapshot service. Use LAN HTTP only for local tests.

The app creates single-use invitations and saves independent bearer credentials.
create-pair still supports legacy manual tokens. iPhones render wallpaper locally.
"""
import argparse
import base64
import binascii
import getpass
import hashlib
import hmac
import json
import os
import re
import secrets
import sqlite3
import tempfile
import threading
import time
import warnings
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from socketserver import TCPServer
from pathlib import Path
from urllib.parse import urlsplit
from urllib.request import Request, urlopen

MAX_BODY = 8_000_000
MAX_BOARD_BYTES = 3_000_000
MAX_STROKES = 3000
MAX_RELAY_IMAGES = 52  # Three latest canvases and the temporary legacy base.
PAIRING_TTL = 300
PAIRING_RECOVERY_TTL = 86400
MAX_PAIRING_SESSIONS = 100
lock = threading.RLock()
state_changed = threading.Condition(lock)


class SyncHTTPServer(ThreadingHTTPServer):
    def __init__(self, server_address, handler, bind_and_activate=True, *,
                 max_connections=64, request_timeout=45):
        self.worker_slots = threading.BoundedSemaphore(max_connections)
        self.request_timeout = request_timeout
        super().__init__(server_address, handler, bind_and_activate)

    def process_request(self, request, client_address):
        if not self.worker_slots.acquire(blocking=False):
            try:
                request.settimeout(1)
                request.sendall(b"HTTP/1.0 503 Service Unavailable\r\n"
                                b"Content-Length: 0\r\nConnection: close\r\nRetry-After: 1\r\n\r\n")
            except OSError:
                pass
            finally:
                self.shutdown_request(request)
            return
        try:
            # Longer than the maximum 25-second long poll, but bounded for
            # clients that stop sending headers or the declared request body.
            request.settimeout(self.request_timeout)
            super().process_request(request, client_address)
        except BaseException:
            self.worker_slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.worker_slots.release()

    def server_bind(self):
        # HTTPServer performs reverse DNS here, which can stall local startup.
        # This service does not use the resolved hostname.
        TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


class MediaFiles:
    """Private, content-addressed images; SQLite keeps placement and references."""
    def __init__(self, db_path, directory=None):
        self.root = Path(directory or (str(db_path) + ".media")).resolve()
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)

    def path(self, ident):
        if not isinstance(ident, str) or not re.fullmatch(r"[0-9a-f]{64}", ident):
            raise ValueError("Invalid stored media reference")
        return self.root / (ident + ".image")

    def store_image(self, item):
        if item is None or "data" not in item:
            return item
        image = base64.b64decode(item["data"], validate=True)
        ident = hashlib.sha256(image).hexdigest()
        target = self.path(ident)
        if not target.exists() or target.read_bytes() != image:
            # The file must be durable before a transaction can reference it.
            temporary = None
            try:
                with tempfile.NamedTemporaryFile(dir=self.root, delete=False) as output:
                    temporary = Path(output.name)
                    output.write(image)
                    output.flush()
                    os.fsync(output.fileno())
                os.replace(temporary, target)
                directory_fd = os.open(self.root, os.O_RDONLY)
                try:
                    os.fsync(directory_fd)
                finally:
                    os.close(directory_fd)
            finally:
                if temporary is not None:
                    temporary.unlink(missing_ok=True)
        result = {key: value for key, value in item.items() if key != "data"}
        result["mediaID"] = ident
        return result

    def store(self, body):
        result = dict(body)
        result["backgroundPhoto"] = self.store_image(body.get("backgroundPhoto"))
        if "stickers" in body:
            result["stickers"] = [self.store_image(item) for item in body["stickers"]]
        return result

    def restore_image(self, item, relay=False):
        if item is not None and "mediaID" in item:
            result = dict(item) if relay else {key: value for key, value in item.items() if key != "mediaID"}
            try:
                image = self.path(item["mediaID"]).read_bytes()
            except FileNotFoundError:
                if relay:
                    # A delivered original lives on the phones. Keep its hash
                    # and placement so they can reuse it or request a resend.
                    return result
                raise
            if hashlib.sha256(image).hexdigest() != item["mediaID"]:
                raise ValueError("Stored media is damaged")
            result["data"] = base64.b64encode(image).decode()
            return result
        return item

    def restore(self, body, relay=False):
        if body is None:
            return None
        result = dict(body)
        result["backgroundPhoto"] = self.restore_image(body.get("backgroundPhoto"), relay)
        if "stickers" in body:
            result["stickers"] = [self.restore_image(item, relay) for item in body["stickers"]]
        return result

    def references(self, db, pair_id=None):
        result = {}
        where = " WHERE pair_id=?" if pair_id is not None else ""
        parameters = (pair_id,) if pair_id is not None else ()
        rows = db.execute("SELECT pair_id, source, revision, body FROM snapshots" + where, parameters).fetchall()
        rows += [(pair, "base", (json.loads(raw) or {}).get("revision", 0), raw)
                 for pair, raw in db.execute("SELECT pair_id, body FROM shared_base" + where, parameters)]
        for pair, source, revision, raw in rows:
            body = json.loads(raw)
            if body is None:
                continue
            identifiers = set()
            for item in [body.get("backgroundPhoto"), *body.get("stickers", [])]:
                if item and "mediaID" in item:
                    self.path(item["mediaID"])
                    identifiers.add(item["mediaID"])
            result[(pair, source, revision)] = identifiers
        return result

    @staticmethod
    def changed(db, pair_id):
        db.execute("INSERT INTO media_generation VALUES (?, 1) ON CONFLICT(pair_id) DO UPDATE SET revision=revision+1", (pair_id,))

    def prune(self, db):
        # BEGIN IMMEDIATE also serializes readers and other server processes.
        # A shared hash is kept until EVERY pair/revision referencing it has
        # receipts from both phones. HTTP delivery alone never grants a receipt.
        references = self.references(db)
        receipts = {(pair, source, revision, role) for pair, source, revision, role
                    in db.execute("SELECT pair_id, source, revision, role FROM media_deliveries")}
        needed = set()
        for (pair, source, revision), identifiers in references.items():
            if not all((pair, source, revision, role) in receipts for role in ("A", "B")):
                needed.update(identifiers)
        for pair, source, revision, role in receipts:
            if (pair, source, revision) not in references:
                db.execute("DELETE FROM media_deliveries WHERE pair_id=? AND source=? AND revision=? AND role=?",
                           (pair, source, revision, role))
        for pair, ident, role in db.execute("SELECT pair_id, media_id, role FROM media_requests").fetchall():
            if not any(key[0] == pair and ident in ids for key, ids in references.items()):
                db.execute("DELETE FROM media_requests WHERE pair_id=? AND media_id=? AND role=?", (pair, ident, role))
        removed = 0
        for file in self.root.glob("*.image"):
            if re.fullmatch(r"[0-9a-f]{64}", file.stem) and file.stem not in needed:
                removed += file.stat().st_size
                file.unlink()
        return removed


def prepare_media(db_path, media, compact=False):
    """Migrate old inline images transactionally, then reclaim unused storage."""
    migrated = 0
    with connect(db_path) as db:
        db.execute("BEGIN IMMEDIATE")
        # Once the new board exists, the legacy seed is no longer needed.
        db.execute("UPDATE shared_base SET body='null' WHERE pair_id IN (SELECT pair_id FROM whiteboards)")
        for table, keys in (("snapshots", ("pair_id", "source")), ("shared_base", ("pair_id",))):
            rows = db.execute(f"SELECT {', '.join(keys)}, body FROM {table}").fetchall()
            for row in rows:
                body = json.loads(row[-1])
                if body and any(item and "data" in item for item in [body.get("backgroundPhoto"), *body.get("stickers", [])]):
                    stored = media.store(body)
                    where = " AND ".join(key + "=?" for key in keys)
                    db.execute(f"UPDATE {table} SET body=? WHERE {where}",
                               (json.dumps(stored, separators=(",", ":")), *row[:-1]))
                    migrated += 1
        db.commit()
        db.execute("BEGIN IMMEDIATE")
        removed = media.prune(db)
        db.commit()
        if compact or migrated:
            db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            db.execute("VACUUM")
    return migrated, removed


class Database(sqlite3.Connection):
    def __exit__(self, *args):
        try:
            return super().__exit__(*args)
        finally:
            self.close()


def connect(path):
    if str(path) != ":memory:":
        try:
            descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_RDWR, 0o600)
        except FileExistsError:
            pass
        else:
            os.close(descriptor)
    db = sqlite3.connect(path, timeout=10, factory=Database)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("CREATE TABLE IF NOT EXISTS members (token_hash TEXT PRIMARY KEY, pair_id TEXT NOT NULL, role TEXT NOT NULL)")
    db.execute("CREATE TABLE IF NOT EXISTS snapshots (pair_id TEXT NOT NULL, source TEXT NOT NULL, revision INTEGER NOT NULL, body TEXT NOT NULL, PRIMARY KEY(pair_id, source))")
    db.execute("CREATE TABLE IF NOT EXISTS devices (pair_id TEXT NOT NULL, role TEXT NOT NULL, token TEXT NOT NULL, environment TEXT NOT NULL DEFAULT 'auto', PRIMARY KEY(pair_id, role))")
    db.execute("CREATE TABLE IF NOT EXISTS ntfy_topics (pair_id TEXT NOT NULL, role TEXT NOT NULL, topic TEXT NOT NULL UNIQUE, PRIMARY KEY(pair_id, role))")
    db.execute("CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
    db.execute("CREATE TABLE IF NOT EXISTS shared_drafts (pair_id TEXT NOT NULL, role TEXT NOT NULL, revision INTEGER NOT NULL, drawing_data TEXT NOT NULL, drawing_height REAL NOT NULL, PRIMARY KEY(pair_id, role))")
    db.execute("CREATE TABLE IF NOT EXISTS shared_base (pair_id TEXT PRIMARY KEY, body TEXT NOT NULL)")
    db.execute("CREATE TABLE IF NOT EXISTS whiteboards (pair_id TEXT PRIMARY KEY, revision INTEGER NOT NULL)")
    db.execute("CREATE TABLE IF NOT EXISTS board_strokes (pair_id TEXT NOT NULL, id TEXT NOT NULL, data TEXT NOT NULL, height REAL NOT NULL, added_revision INTEGER NOT NULL, deleted_revision INTEGER, PRIMARY KEY(pair_id, id))")
    db.execute("CREATE TABLE IF NOT EXISTS board_operations (pair_id TEXT NOT NULL, id TEXT NOT NULL, digest TEXT NOT NULL, PRIMARY KEY(pair_id, id))")
    db.execute("CREATE TABLE IF NOT EXISTS pairing_sessions (id TEXT PRIMARY KEY, code TEXT NOT NULL UNIQUE, creator_hash TEXT NOT NULL UNIQUE, joiner_hash TEXT UNIQUE, token_a_hash TEXT NOT NULL, expires_at INTEGER NOT NULL, recover_until INTEGER)")
    db.execute("CREATE TABLE IF NOT EXISTS pairing_limits (bucket TEXT NOT NULL, window INTEGER NOT NULL, hits INTEGER NOT NULL, PRIMARY KEY(bucket, window))")
    db.execute("CREATE TABLE IF NOT EXISTS media_deliveries (pair_id TEXT NOT NULL, source TEXT NOT NULL, revision INTEGER NOT NULL, role TEXT NOT NULL, PRIMARY KEY(pair_id, source, revision, role))")
    db.execute("CREATE TABLE IF NOT EXISTS media_requests (pair_id TEXT NOT NULL, media_id TEXT NOT NULL, role TEXT NOT NULL, PRIMARY KEY(pair_id, media_id, role))")
    db.execute("CREATE TABLE IF NOT EXISTS media_generation (pair_id TEXT PRIMARY KEY, revision INTEGER NOT NULL)")
    db.commit()
    return db


class PairingError(Exception):
    def __init__(self, status, message, retry_after=None):
        super().__init__(message)
        self.status, self.retry_after = status, retry_after


class PairingService:
    """Single-use invitations. SQLite serializes joins across server processes.

    Each phone saves a random 256-bit recovery secret before sending anything.
    HMAC derives its credential on demand; only hashes of secrets and credentials
    are stored. Knowing the six-digit invitation never reveals A's credential.
    """
    def __init__(self, db_path):
        self.db_path = db_path

    @staticmethod
    def digest(secret):
        return hashlib.sha256(secret.encode("ascii")).hexdigest()

    @staticmethod
    def credential(secret, session_id, role):
        return hmac.new(bytes.fromhex(secret),
                        f"CoupleDraw pair credential v1:{session_id}:{role}".encode("ascii"),
                        hashlib.sha256).hexdigest()

    @staticmethod
    def clean(db, now):
        db.execute("DELETE FROM pairing_sessions WHERE (joiner_hash IS NULL AND expires_at<=?) OR (joiner_hash IS NOT NULL AND recover_until<=?)", (now, now))
        db.execute("DELETE FROM pairing_limits WHERE window<?", (now // 60 - 1,))

    @staticmethod
    def limit(db, action, peer, now):
        # Use the actual TCP peer, never an untrusted forwarding header. Reverse
        # proxies should add their own per-client limits before this global cap.
        window = now // 60
        buckets = [(action + ":peer:" + peer, 5 if action != "status" else 60),
                   (action + ":global", 30 if action != "status" else 180)]
        for bucket, maximum in buckets:
            row = db.execute("SELECT hits FROM pairing_limits WHERE bucket=? AND window=?", (bucket, window)).fetchone()
            if row and row[0] >= maximum:
                raise PairingError(429, "Too many pairing attempts. Wait a minute and try again.", 60 - now % 60)
        for bucket, _ in buckets:
            db.execute("INSERT INTO pairing_limits VALUES (?, ?, 1) ON CONFLICT(bucket, window) DO UPDATE SET hits=hits+1", (bucket, window))
        # Failed guesses must count even when the following operation rolls back.
        db.commit()
        db.execute("BEGIN IMMEDIATE")

    def handle(self, action, obj, peer, wait=0):
        fields = {"secret", "code"} if action == "join" else {"secret"}
        if (action not in ("create", "join", "status", "cancel") or
                not isinstance(obj, dict) or set(obj) != fields or
                not isinstance(obj.get("secret"), str) or
                not re.fullmatch(r"[0-9a-f]{64}", obj["secret"])):
            raise PairingError(400, "Invalid pairing request")
        if action == "join" and (not isinstance(obj["code"], str) or not re.fullmatch(r"[0-9]{6}", obj["code"])):
            raise PairingError(400, "Enter the six-digit pairing code")
        secret = obj["secret"]
        digest = self.digest(secret)
        deadline = time.monotonic() + min(max(wait, 0), 20)
        first = True
        with state_changed:
            while True:
                now = int(time.time())
                with connect(self.db_path) as db:
                    db.execute("BEGIN IMMEDIATE")
                    now = int(time.time())
                    self.clean(db, now)
                    column = "joiner_hash" if action == "join" else "creator_hash"
                    row = db.execute(f"SELECT id, code, joiner_hash, expires_at, recover_until FROM pairing_sessions WHERE {column}=?", (digest,)).fetchone()
                    if action == "cancel":
                        if (row and row[2] is not None) or db.execute("SELECT 1 FROM pairing_sessions WHERE joiner_hash=?", (digest,)).fetchone():
                            raise PairingError(409, "Your partner has joined. Finish connecting to keep this pair.")
                        db.execute("DELETE FROM pairing_sessions WHERE creator_hash=?", (digest,))
                        db.commit()
                        state_changed.notify_all()
                        return {"state": "cancelled"}
                    if row and row[2] is not None:
                        role = "B" if action == "join" else "A"
                        return {"state": "paired", "role": role,
                                "credential": self.credential(secret, row[0], role)}
                    if first and not (action == "create" and row):
                        self.limit(db, action, peer, now)
                        now = int(time.time())
                        # Re-read after the limiter commits: another process may
                        # have joined, cancelled or expired the invitation.
                        self.clean(db, now)
                        row = db.execute(f"SELECT id, code, joiner_hash, expires_at, recover_until FROM pairing_sessions WHERE {column}=?", (digest,)).fetchone()
                        if row and row[2] is not None:
                            role = "B" if action == "join" else "A"
                            return {"state": "paired", "role": role,
                                    "credential": self.credential(secret, row[0], role)}
                    if action == "create":
                        if row is None:
                            if db.execute("SELECT 1 FROM pairing_sessions WHERE joiner_hash=?", (digest,)).fetchone():
                                raise PairingError(409, "Use a new private pairing secret")
                            if db.execute("SELECT COUNT(*) FROM pairing_sessions").fetchone()[0] >= MAX_PAIRING_SESSIONS:
                                raise PairingError(429, "The server has too many recent pairing sessions. Try again later.", 300)
                            session_id = secrets.token_hex(16)
                            for _ in range(100):
                                code = f"{secrets.randbelow(1_000_000):06d}"
                                if not db.execute("SELECT 1 FROM pairing_sessions WHERE code=?", (code,)).fetchone():
                                    break
                            else:
                                raise PairingError(503, "Could not create an invitation. Try again.")
                            expires = now + PAIRING_TTL
                            db.execute("INSERT INTO pairing_sessions VALUES (?, ?, ?, NULL, ?, ?, NULL)",
                                       (session_id, code, digest, self.digest(self.credential(secret, session_id, "A")), expires))
                            row = (session_id, code, None, expires, None)
                        return {"state": "waiting", "code": row[1], "expiresAt": row[3]}
                    if action == "join":
                        if db.execute("SELECT 1 FROM pairing_sessions WHERE creator_hash=?", (digest,)).fetchone():
                            raise PairingError(409, "Use a different phone to join this pair")
                        invite = db.execute("SELECT id, token_a_hash FROM pairing_sessions WHERE code=? AND joiner_hash IS NULL AND expires_at>?", (obj["code"], now)).fetchone()
                        if invite is None:
                            raise PairingError(410, "This code expired or was already used. Ask your partner for a new code.")
                        credential = self.credential(secret, invite[0], "B")
                        db.executemany("INSERT INTO members VALUES (?, ?, ?)",
                                       [(invite[1], invite[0], "A"), (self.digest(credential), invite[0], "B")])
                        db.execute("UPDATE pairing_sessions SET joiner_hash=?, recover_until=? WHERE id=?", (digest, now + PAIRING_RECOVERY_TTL, invite[0]))
                        db.commit()
                        state_changed.notify_all()
                        return {"state": "paired", "role": "B", "credential": credential}
                    if row is None:
                        raise PairingError(410, "This pairing session expired or was cancelled. Create a new code.")
                    remaining = min(deadline - time.monotonic(), row[3] - time.time())
                    if remaining <= 0:
                        return {"state": "waiting", "code": row[1], "expiresAt": row[3]}
                # No SQLite transaction stays open while the creator waits.
                state_changed.wait(timeout=min(remaining, 1))
                first = False


def board_update(db, pair_id, since=None):
    row = db.execute("SELECT revision FROM whiteboards WHERE pair_id=?", (pair_id,)).fetchone()
    if not row:
        return None
    revision = row[0]
    full = type(since) is not int or not 1 <= since <= revision
    if full:
        strokes = db.execute("SELECT id, data, height FROM board_strokes WHERE pair_id=? AND deleted_revision IS NULL ORDER BY added_revision, rowid", (pair_id,)).fetchall()
        removed = []
    else:
        strokes = db.execute("SELECT id, data, height FROM board_strokes WHERE pair_id=? AND added_revision>? AND deleted_revision IS NULL ORDER BY added_revision, rowid", (pair_id, since)).fetchall()
        removed = [r[0] for r in db.execute("SELECT id FROM board_strokes WHERE pair_id=? AND deleted_revision>?", (pair_id, since))]
    return {"revision": revision, "baseRevision": None if full else since,
            "strokes": [{"id": i, "drawingData": data, "drawingHeight": h} for i, data, h in strokes],
            "removed": removed}


def legacy_seed(db, pair_id):
    db.execute("INSERT OR IGNORE INTO shared_base (pair_id, body) SELECT ?, COALESCE((SELECT body FROM snapshots WHERE pair_id=? AND source='together'), 'null')", (pair_id, pair_id))
    base = db.execute("SELECT body FROM shared_base WHERE pair_id=?", (pair_id,)).fetchone()[0]
    drafts = db.execute("SELECT role, revision, drawing_data, drawing_height FROM shared_drafts WHERE pair_id=? ORDER BY role", (pair_id,)).fetchall()
    tag = hashlib.sha256(json.dumps([base, drafts], separators=(",", ":")).encode()).hexdigest()
    return tag


def valid_strokes(strokes):
    if not isinstance(strokes, list) or len(strokes) > MAX_STROKES:
        raise ValueError("Too many strokes")
    ids = set()
    for stroke in strokes:
        if not isinstance(stroke, dict) or set(stroke) != {"id", "drawingData", "drawingHeight"}:
            raise ValueError("Invalid stroke")
        ident, data, height = stroke["id"], stroke["drawingData"], stroke["drawingHeight"]
        if not isinstance(ident, str) or not re.fullmatch(r"[A-Za-z0-9-]{1,80}", ident) or ident in ids:
            raise ValueError("Invalid stroke ID")
        ids.add(ident)
        if (not isinstance(data, str) or not 0 < len(base64.b64decode(data, validate=True)) <= MAX_BOARD_BYTES or
                type(height) not in (int, float) or not 300 <= height <= 2000):
            raise ValueError("Invalid stroke data")
    return strokes


def push_configured():
    return all(os.environ.get(name) for name in
               ("APNS_KEY_FILE", "APNS_KEY_ID", "APNS_TEAM_ID", "APNS_TOPIC"))


def validate_ntfy_base_url(raw):
    raw = raw.strip().rstrip("/")
    parts = urlsplit(raw)
    if (parts.scheme != "https" or not parts.hostname or parts.path or parts.query or
            parts.fragment or parts.username or parts.password or any(c.isspace() for c in raw)):
        raise ValueError("Enter the HTTPS server base URL, e.g. https://ntfy.sh (without a /topic path)")
    return raw


def ntfy_base_url(db_path):
    raw = os.environ.get("NTFY_BASE_URL")
    if not raw:
        with connect(db_path) as db:
            row = db.execute("SELECT value FROM settings WHERE key='ntfy_base_url'").fetchone()
        raw = row[0] if row else None
    return validate_ntfy_base_url(raw) if raw else None


def configure_ntfy(db_path):
    current = ntfy_base_url(db_path) or "https://ntfy.sh"
    base = validate_ntfy_base_url(input(f"ntfy base URL [{current}]: ") or current)
    with connect(db_path) as db:
        db.execute("INSERT OR REPLACE INTO settings (key, value) VALUES ('ntfy_base_url', ?)", (base,))
    print(f"Saved ntfy base URL: {base}. Restart the server to use it.")
    print("Each phone's private topic is a separate path, shown under Pair → Alerts through ntfy.")


def recipient_topic(db_path, pair_id, role):
    with connect(db_path) as db:
        db.execute("INSERT OR IGNORE INTO ntfy_topics VALUES (?, ?, ?)",
                   (pair_id, role, "coupledraw-" + secrets.token_urlsafe(24)))
        return db.execute("SELECT topic FROM ntfy_topics WHERE pair_id=? AND role=?",
                          (pair_id, role)).fetchone()[0]


def send_ntfy(db_path, pair_id, recipient, revision):
    base = ntfy_base_url(db_path)
    if not base:
        return
    topic = recipient_topic(db_path, pair_id, recipient)
    request = Request(f"{base}/{topic}", data=b"Your partner applied a new drawing.",
                      headers={"Title": "CoupleDraw wallpaper ready", "Content-Type": "text/plain"},
                      method="POST")
    try:
        with urlopen(request, timeout=10) as response:
            if response.status != 200:
                raise RuntimeError(f"ntfy returned HTTP {response.status}")
        print(f"ntfy accepted revision {revision} for role {recipient}")
    except Exception as error:
        print(f"ntfy send failed for revision {revision}: {type(error).__name__}: {error}")


def provider_token():
    """Sign an ES256 APNs provider JWT using the server's private .p8 key."""
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

    def encoded(value):
        return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")

    header = encoded(json.dumps({"alg": "ES256", "kid": os.environ["APNS_KEY_ID"]},
                                separators=(",", ":")).encode())
    claims = encoded(json.dumps({"iss": os.environ["APNS_TEAM_ID"], "iat": int(time.time())},
                                separators=(",", ":")).encode())
    signing_input = f"{header}.{claims}"
    key = serialization.load_pem_private_key(Path(os.environ["APNS_KEY_FILE"]).read_bytes(), password=None)
    if not isinstance(key, ec.EllipticCurvePrivateKey) or not isinstance(key.curve, ec.SECP256R1):
        raise ValueError("APNS_KEY_FILE must contain an ES256 APNs key")
    der = key.sign(signing_input.encode("ascii"), ec.ECDSA(hashes.SHA256()))
    r, s = decode_dss_signature(der)
    return f"{signing_input}.{encoded(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))}"


def notify_partner(db_path, pair_id, author, source, revision):
    recipient = "B" if author == "A" else "A"
    if ntfy_base_url(db_path):
        send_ntfy(db_path, pair_id, recipient, revision)
    if not push_configured():
        return
    with connect(db_path) as db:
        row = db.execute("SELECT token, environment FROM devices WHERE pair_id=? AND role=?",
                         (pair_id, recipient)).fetchone()
    if not row:
        return
    try:
        import httpx  # Install with: python3 -m pip install 'httpx[http2]' cryptography
        jwt = provider_token()
        body = {"aps": {"alert": {"title": "CoupleDraw wallpaper ready",
                                      "body": "Your partner applied a new drawing."}, "sound": "default"},
                "source": source, "revision": revision}
        headers = {"authorization": f"bearer {jwt}", "apns-topic": os.environ["APNS_TOPIC"],
                   "apns-push-type": "alert", "apns-priority": "10"}
        environments = [row[1]] if row[1] != "auto" else ["production", "sandbox"]
        with httpx.Client(http2=True, timeout=10) as client:
            for environment in environments:
                host = "api.push.apple.com" if environment == "production" else "api.sandbox.push.apple.com"
                response = client.post(f"https://{host}/3/device/{row[0]}", json=body, headers=headers)
                if response.status_code == 200:
                    with connect(db_path) as db:
                        db.execute("UPDATE devices SET environment=? WHERE pair_id=? AND role=? AND token=?",
                                   (environment, pair_id, recipient, row[0]))
                    print(f"APNs accepted revision {revision} for role {recipient}")
                    return
                reason = response.json().get("reason", "Unknown")
                if environment == "production" and reason == "BadDeviceToken" and row[1] == "auto":
                    continue
                print(f"APNs rejected revision {revision} for role {recipient}: {response.status_code} {reason}")
                return
    except Exception as error:
        print(f"APNs send failed for revision {revision}: {type(error).__name__}: {error}")


def chosen_token(role):
    with warnings.catch_warnings():
        warnings.simplefilter("error", getpass.GetPassWarning)
        token = getpass.getpass(f"Choose token {role} (20-100 characters, letters/numbers/._~-): ")
        if not re.fullmatch(r"[A-Za-z0-9._~-]{20,100}", token):
            raise ValueError("Use 20-100 letters, numbers, or . _ ~ - characters for each token")
        confirmation = getpass.getpass(f"Repeat token {role}: ")
    if not secrets.compare_digest(token, confirmation):
        raise ValueError(f"Token {role} did not match its confirmation")
    return token


def pair(db_path, custom_tokens=False):
    pair_id = secrets.token_hex(16)
    tokens = [chosen_token(role) for role in ("A", "B")] if custom_tokens else [
        secrets.token_urlsafe(32), secrets.token_urlsafe(32)]
    if secrets.compare_digest(tokens[0], tokens[1]):
        raise ValueError("A and B must have different tokens")
    try:
        with connect(db_path) as db:
            for role, token in zip(("A", "B"), tokens):
                db.execute("INSERT INTO members VALUES (?, ?, ?)",
                           (hashlib.sha256(token.encode()).hexdigest(), pair_id, role))
    except sqlite3.IntegrityError as error:
        raise ValueError("A token is already in this database; choose new tokens") from error
    if custom_tokens:
        print("Pair created. Give each person only their own A or B token; chosen tokens are not printed.")
    else:
        print("Give each person only their own private token:")
        for role, token in zip(("A", "B"), tokens):
            print(f"{role}: {token}")


def serve(db_path, host, port, media_dir=None):
    media = MediaFiles(db_path, media_dir)
    migrated, removed = prepare_media(db_path, media)
    ntfy = ntfy_base_url(db_path)
    if push_configured():
        try:
            import httpx
            provider_token()
        except (ImportError, OSError, ValueError) as error:
            raise SystemExit(f"APNs setup incomplete: {error}") from error

    class Handler(BaseHTTPRequestHandler):
        def read_json(self, limit):
            lengths = self.headers.get_all("Content-Length", [])
            if (self.headers.get("Transfer-Encoding") is not None or len(lengths) != 1 or
                    not re.fullmatch(r"[0-9]{1,10}", lengths[0])):
                raise ValueError("Invalid body framing")
            size = int(lengths[0])
            if not 0 < size <= limit:
                raise ValueError("Invalid body size")
            raw = self.rfile.read(size)
            if len(raw) != size:
                raise ValueError("Incomplete body")
            try:
                return json.loads(raw)
            except RecursionError as error:
                raise ValueError("JSON is nested too deeply") from error

        def begin_request(self):
            self.started_at = time.perf_counter()
            self.client_role = "-"
            self.event_detail = ""

        def reply(self, status, body, headers=None):
            data = json.dumps(body, separators=(",", ":")).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(data)))
            for name, value in (headers or {}).items():
                self.send_header(name, value)
            self.end_headers()
            self.wfile.write(data)

        def member(self):
            header = self.headers.get("Authorization", "")
            if not header.startswith("Bearer "):
                return None
            token = header[7:]
            if len(token) > 100:
                return None
            digest = hashlib.sha256(token.encode()).hexdigest()
            with connect(db_path) as db:
                member = db.execute("SELECT pair_id, role FROM members WHERE token_hash=?", (digest,)).fetchone()
            if member:
                self.client_role = member[1]
            return member

        def do_GET(self):
            self.begin_request()
            member = self.member()
            if not member:
                return self.reply(401, {"error": "Invalid pairing token"})
            if self.path != "/v1/state":
                return self.reply(404, {"error": "Not found"})
            # Older clients omit Prefer. Bound waits so a proxy can retry safely.
            preferences = [part.strip().lower() for part in self.headers.get("Prefer", "").split(",")]
            wait = next((int(part[5:]) for part in preferences
                         if re.fullmatch(r"wait=[0-9]{1,2}", part) and
                         1 <= int(part[5:]) <= 25), 0)
            deadline = time.monotonic() + wait
            def known_versions(header):
                result = {}
                for pair in self.headers.get(header, "").split(","):
                    key, separator, value = pair.partition(":")
                    if separator and re.fullmatch(r"[0-9]{1,19}", value) and len(key) <= 16:
                        result[key] = int(value)
                return result

            known_snapshots = known_versions("X-CoupleDraw-Snapshots")
            known_drafts = known_versions("X-CoupleDraw-Drafts")
            relay = self.headers.get("X-CoupleDraw-Media") == "2"
            topic = recipient_topic(db_path, member[0], member[1]) if ntfy else None
            push = push_configured()
            with state_changed:
                while True:
                    with connect(db_path) as db:
                        db.execute("BEGIN IMMEDIATE")
                        # Freeze the pre-collaboration snapshot as the base. Later
                        # Applies are saved revisions, not new editable base strokes.
                        db.execute("INSERT OR IGNORE INTO shared_base (pair_id, body) SELECT ?, COALESCE((SELECT body FROM snapshots WHERE pair_id=? AND source='together'), 'null')",
                                   (member[0], member[0]))
                        board = board_update(db, member[0], self.board_since())
                        seed_tag = legacy_seed(db, member[0]) if board is None else None
                        base_row = db.execute("SELECT body FROM shared_base WHERE pair_id=?", (member[0],)).fetchone()
                        rows = db.execute("SELECT source, revision, body FROM snapshots WHERE pair_id=? ORDER BY source",
                                          (member[0],)).fetchall()
                        drafts = db.execute("SELECT role, revision, drawing_data, drawing_height FROM shared_drafts WHERE pair_id=? ORDER BY role",
                                            (member[0],)).fetchall()
                        generation = db.execute("SELECT revision FROM media_generation WHERE pair_id=?", (member[0],)).fetchone()
                        inventory = [{"source": source, "revision": revision, "mediaIDs": sorted(identifiers)}
                                     for (_, source, revision), identifiers in media.references(db, member[0]).items()]
                        requests = sorted({ident for ident, in db.execute(
                            "SELECT media_id FROM media_requests WHERE pair_id=? AND role<>?", member)
                                           if not media.path(ident).exists()}) if relay else []
                        marker = json.dumps([member[1], push, topic, ntfy,
                                         [(source, revision) for source, revision, _ in rows],
                                         [(role, revision) for role, revision, _, _ in drafts],
                                         board["revision"] if board else None, relay,
                                         generation[0] if generation else 0],
                                        separators=(",", ":")).encode()
                        etag = '"' + hashlib.sha256(marker).hexdigest()[:24] + '"'
                        remaining = deadline - time.monotonic()
                        if self.headers.get("If-None-Match") != etag:
                            try:
                                changed_snapshots = [media.restore(json.loads(body), relay) for source, revision, body in rows
                                                     if known_snapshots.get(source) != revision]
                                hydrated_base = None if self.headers.get("X-CoupleDraw-Base-Known") == "1" else media.restore(json.loads(base_row[0]), relay)
                            except (OSError, ValueError):
                                return self.reply(503, {"error": "A stored photo is unavailable. Update CoupleDraw on both phones for temporary media delivery, or re-apply the photo from a phone."})
                    if self.headers.get("If-None-Match") != etag or remaining <= 0:
                        break
                    # Recheck SQLite periodically in case another server process
                    # wrote to the same database (Condition only wakes this process).
                    state_changed.wait(timeout=min(remaining, 1))
            self.event_detail = f" prefer_wait={wait} waited_ms={(time.monotonic() - (deadline - wait)) * 1000:.1f}"
            if self.headers.get("If-None-Match") == etag:
                self.send_response(304)
                self.send_header("Cache-Control", "no-store")
                self.send_header("ETag", etag)
                self.send_header("X-CoupleDraw-Long-Poll", "1")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            changed_drafts = [{"role": role, "revision": revision,
                               "drawingData": data, "drawingHeight": height}
                              for role, revision, data, height in drafts
                              if known_drafts.get(role) != revision]
            partner_source = "b" if member[1] == "A" else "a"
            return self.reply(200, {"role": member[1], "pushConfigured": push,
                                    "ntfyTopic": topic, "ntfyBaseURL": ntfy,
                                    "hasPartnerArt": any(source == partner_source for source, _, _ in rows),
                                    "items": changed_snapshots,
                                    "mediaProtocol": 2 if relay else 1,
                                    "mediaInventory": inventory if relay else None,
                                    "mediaRequests": requests if relay else None,
                                    "boardProtocol": 1, "boardSeedTag": seed_tag,
                                    "board": board if board and board["revision"] != self.board_since() else None,
                                    "sharedBase": None if self.headers.get("X-CoupleDraw-Base-Known") == "1"
                                    else hydrated_base,
                                    "draftRevisions": {role: revision for role, revision, _, _ in drafts},
                                    "drafts": changed_drafts},
                              {"ETag": etag, "X-CoupleDraw-Long-Poll": "1"})

        def board_since(self):
            raw = self.headers.get("X-CoupleDraw-Board", "")
            return int(raw) if re.fullmatch(r"[0-9]{1,11}", raw) else None

        def relay_media(self, member):
            """Receipts and recovery use pair-scoped references, never public URLs."""
            action = self.path.rsplit("/", 1)[1]
            try:
                obj = self.read_json(1_250_000 if action == "restore" else 8192)
                if not isinstance(obj, dict):
                    raise ValueError("Invalid media request")
                if action == "ack":
                    receipts = obj["receipts"]
                    if not isinstance(receipts, list) or not 1 <= len(receipts) <= 4:
                        raise ValueError("Invalid media receipts")
                    seen = set()
                    for receipt in receipts:
                        if (not isinstance(receipt, dict) or set(receipt) != {"source", "revision", "mediaIDs"} or
                                receipt["source"] not in ("a", "b", "together", "base") or
                                type(receipt["revision"]) is not int or not 1 <= receipt["revision"] < 2**63 or
                                receipt["source"] in seen):
                            raise ValueError("Invalid media receipt")
                        seen.add(receipt["source"])
                        self.valid_media_ids(receipt["mediaIDs"], maximum=13)
                elif action == "request":
                    self.valid_media_ids(obj["mediaIDs"])
                else:
                    ident = obj["mediaID"]
                    media.path(ident)
                    image = base64.b64decode(obj["data"], validate=True)
                    if (not 0 < len(image) <= 900_000 or hashlib.sha256(image).hexdigest() != ident or
                            not (image.startswith(b"\xff\xd8") or image.startswith(b"\x89PNG\r\n\x1a\n"))):
                        raise ValueError("Invalid restored image")
            except (ValueError, KeyError, TypeError, binascii.Error):
                return self.reply(400, {"error": "Invalid media delivery request"})

            with state_changed, connect(db_path) as db:
                db.execute("BEGIN IMMEDIATE")
                references = media.references(db, member[0])
                identifiers = set().union(*references.values()) if references else set()
                if action == "ack":
                    accepted = []
                    for receipt in receipts:
                        key = (member[0], receipt["source"], receipt["revision"])
                        # A superseded revision cannot acknowledge its replacement.
                        if references.get(key) != set(receipt["mediaIDs"]):
                            continue
                        db.execute("INSERT OR IGNORE INTO media_deliveries VALUES (?, ?, ?, ?)", (*key, member[1]))
                        accepted.append(receipt)
                    # A resend is complete only when all references to the image
                    # on this phone have fresh receipts, not when bytes are sent.
                    for ident, in db.execute("SELECT media_id FROM media_requests WHERE pair_id=? AND role=?", member).fetchall():
                        keys = [key for key, ids in references.items() if ident in ids]
                        if keys and all(db.execute("SELECT 1 FROM media_deliveries WHERE pair_id=? AND source=? AND revision=? AND role=?",
                                                   (*key, member[1])).fetchone() for key in keys):
                            db.execute("DELETE FROM media_requests WHERE pair_id=? AND media_id=? AND role=?", (member[0], ident, member[1]))
                            media.changed(db, member[0])
                    db.commit()  # Receipts are durable before any file is removed.
                    db.execute("BEGIN IMMEDIATE")
                    try:
                        removed = media.prune(db)
                    except OSError:
                        removed = 0
                        print("Media cleanup deferred until next server start.", flush=True)
                    db.commit()
                    state_changed.notify_all()
                    result = {"accepted": accepted, "removedBytes": removed}
                    self.event_detail = f" receipts={len(accepted)} removed_bytes={removed}"
                elif action == "request":
                    if not set(obj["mediaIDs"]) <= identifiers:
                        return self.reply(404, {"error": "Media is not part of this pair's latest artwork"})
                    changed = False
                    for ident in obj["mediaIDs"]:
                        for key, ids in references.items():
                            if ident in ids:
                                changed |= db.execute("DELETE FROM media_deliveries WHERE pair_id=? AND source=? AND revision=? AND role=?",
                                                      (*key, member[1])).rowcount > 0
                        changed |= db.execute("INSERT OR IGNORE INTO media_requests VALUES (?, ?, ?)", (member[0], ident, member[1])).rowcount > 0
                    if changed:
                        media.changed(db, member[0])
                    db.commit()
                    state_changed.notify_all()
                    result = {"queued": True}
                else:
                    if ident not in identifiers:
                        return self.reply(404, {"error": "Media is not part of this pair's latest artwork"})
                    if not db.execute("SELECT 1 FROM media_requests WHERE pair_id=? AND media_id=?", (member[0], ident)).fetchone():
                        return self.reply(409, {"error": "This resend is no longer needed"})
                    was_missing = not media.path(ident).exists()
                    try:
                        media.store_image({"data": obj["data"]})
                    except OSError:
                        return self.reply(507, {"error": "The server could not save the resend. Check available disk space."})
                    if was_missing:
                        for pair in {key[0] for key, ids in media.references(db).items() if ident in ids}:
                            media.changed(db, pair)
                    db.commit()
                    state_changed.notify_all()
                    result = {"restored": True}
            return self.reply(200, result)

        @staticmethod
        def valid_media_ids(identifiers, maximum=MAX_RELAY_IMAGES):
            if (not isinstance(identifiers, list) or not 1 <= len(identifiers) <= maximum or
                    any(not isinstance(ident, str) or not re.fullmatch(r"[0-9a-f]{64}", ident) for ident in identifiers) or
                    len(set(identifiers)) != len(identifiers)):
                raise ValueError("Invalid media identifiers")

        def edit_board(self, member, seed=False):
            try:
                obj = self.read_json(MAX_BODY)
                if not isinstance(obj, dict):
                    raise ValueError("Invalid board request")
                additions = valid_strokes(obj["strokes"] if seed else obj["add"])
                removals = [] if seed else obj["remove"]
                if (not isinstance(removals, list) or len(removals) > MAX_STROKES or
                        any(not isinstance(i, str) or not re.fullmatch(r"[A-Za-z0-9-]{1,80}", i) for i in removals) or
                        len(set(removals)) != len(removals)):
                    raise ValueError("Invalid removed strokes")
                operation = None if seed else obj["id"]
                if not seed and (not isinstance(operation, str) or not re.fullmatch(r"[A-Za-z0-9-]{1,80}", operation)):
                    raise ValueError("Invalid operation ID")
                digest = hashlib.sha256(json.dumps(obj, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
            except (ValueError, KeyError, TypeError, binascii.Error):
                return self.reply(400, {"error": "Invalid whiteboard request"})
            with state_changed, connect(db_path) as db:
                # SQLite serializes writes across processes as well as threads.
                db.execute("BEGIN IMMEDIATE")
                current = board_update(db, member[0])
                if seed:
                    if current is not None:
                        return self.reply(200, current)
                    if obj.get("seedTag") != legacy_seed(db, member[0]):
                        return self.reply(409, {"error": "The old shared draft changed; refresh before upgrading"})
                    revision = 1
                else:
                    if current is None:
                        return self.reply(409, {"error": "Initialize the shared whiteboard first"})
                    old_op = db.execute("SELECT digest FROM board_operations WHERE pair_id=? AND id=?", (member[0], operation)).fetchone()
                    if old_op:
                        if old_op[0] != digest:
                            return self.reply(409, {"error": "Operation ID reused with different edits"})
                        return self.reply(200, board_update(db, member[0], self.board_since()))
                    active = {stroke["id"] for stroke in current["strokes"]}
                    if not set(removals) <= active:
                        return self.reply(409, {"error": "A partner already changed one of these strokes", "board": current})
                    revision = current["revision"] + 1
                for stroke in additions:
                    if db.execute("SELECT 1 FROM board_strokes WHERE pair_id=? AND id=?", (member[0], stroke["id"])).fetchone():
                        return self.reply(409, {"error": "Stroke ID already used", "board": current})
                retained = [stroke for stroke in (current or {}).get("strokes", []) if stroke["id"] not in removals]
                if len(retained) + len(additions) > MAX_STROKES or sum(len(base64.b64decode(x["drawingData"])) for x in retained + additions) > MAX_BOARD_BYTES:
                    return self.reply(413, {"error": "This board is full. Apply to keep it in History, then clear the board."})
                db.executemany("UPDATE board_strokes SET deleted_revision=?, data='' WHERE pair_id=? AND id=?", [(revision, member[0], i) for i in removals])
                db.executemany("INSERT INTO board_strokes VALUES (?, ?, ?, ?, ?, NULL)",
                               [(member[0], stroke["id"], stroke["drawingData"], stroke["drawingHeight"], revision) for stroke in additions])
                db.execute("INSERT OR REPLACE INTO whiteboards VALUES (?, ?)", (member[0], revision))
                if seed:
                    db.execute("UPDATE shared_base SET body='null' WHERE pair_id=?", (member[0],))
                if not seed:
                    db.execute("INSERT INTO board_operations VALUES (?, ?, ?)", (member[0], operation, digest))
                result = board_update(db, member[0], self.board_since())
                db.commit()
                if seed:
                    db.execute("BEGIN IMMEDIATE")
                    try:
                        media.prune(db)
                    except OSError:
                        print("Media cleanup deferred until next server start.", flush=True)
                    db.commit()
                state_changed.notify_all()
            self.event_detail = f" board_revision={revision} added={len(additions)} removed={len(removals)}"
            return self.reply(200, result)

        def do_POST(self):
            self.begin_request()
            if self.path in ("/v1/pairing/create", "/v1/pairing/join", "/v1/pairing/status", "/v1/pairing/cancel"):
                try:
                    obj = self.read_json(1024)
                    action = self.path.rsplit("/", 1)[1]
                    wait = 20 if action == "status" and self.headers.get("Prefer") == "wait=20" else 0
                    result = PairingService(db_path).handle(action, obj, self.client_address[0], wait)
                except PairingError as error:
                    return self.reply(error.status, {"error": str(error)},
                                      {"Retry-After": str(error.retry_after)} if error.retry_after else None)
                except (ValueError, TypeError):
                    return self.reply(400, {"error": "Invalid pairing request"})
                self.client_role = result.get("role", "-")
                return self.reply(200, result)
            member = self.member()
            if not member:
                return self.reply(401, {"error": "Invalid pairing token"})
            if self.path in ("/v1/media/ack", "/v1/media/request", "/v1/media/restore"):
                return self.relay_media(member)
            if self.path in ("/v1/board/seed", "/v1/board/ops"):
                return self.edit_board(member, seed=self.path.endswith("/seed"))
            if self.path == "/v1/device":
                try:
                    data = self.read_json(512)
                    device_token = data["deviceToken"]
                    if not isinstance(device_token, str) or not re.fullmatch(r"[0-9a-f]{64,256}", device_token):
                        raise ValueError("Invalid device token")
                except (ValueError, KeyError, TypeError, json.JSONDecodeError):
                    return self.reply(400, {"error": "Invalid device registration"})
                with connect(db_path) as db:
                    db.execute("INSERT OR REPLACE INTO devices (pair_id, role, token, environment) VALUES (?, ?, ?, 'auto')",
                               (member[0], member[1], device_token))
                return self.reply(200, {"registered": True, "pushConfigured": push_configured()})
            if self.path == "/v1/draft":
                try:
                    obj = self.read_json(1_500_000)
                    data = obj["drawingData"]
                    height = obj["drawingHeight"]
                    if (not isinstance(data, str) or len(base64.b64decode(data, validate=True)) > 1_000_000 or
                            type(height) not in (int, float) or
                            not 300 <= height <= 2000):
                        raise ValueError("Invalid draft")
                except (ValueError, KeyError, TypeError, binascii.Error, json.JSONDecodeError):
                    return self.reply(400, {"error": "Invalid shared draft"})
                with state_changed, connect(db_path) as db:
                    db.execute("BEGIN IMMEDIATE")
                    if board_update(db, member[0]) is not None:
                        return self.reply(409, {"error": "This pair uses the new whiteboard. Update CoupleDraw on both phones."})
                    row = db.execute("SELECT revision FROM shared_drafts WHERE pair_id=? AND role=?",
                                     (member[0], member[1])).fetchone()
                    revision = (row[0] if row else 0) + 1
                    db.execute("INSERT OR REPLACE INTO shared_drafts VALUES (?, ?, ?, ?, ?)",
                               (member[0], member[1], revision, data, height))
                    state_changed.notify_all()
                self.event_detail = f" draft_revision={revision}"
                return self.reply(200, {"role": member[1], "revision": revision})
            if self.path != "/v1/apply":
                return self.reply(404, {"error": "Not found"})
            try:
                obj = self.read_json(MAX_BODY)
                source = obj["source"]
                data = base64.b64decode(obj["drawingData"], validate=True)
                expected = obj["expectedRevision"]
                height = obj["drawingHeight"]
                color = obj["backgroundHex"]
                photo = obj.get("backgroundPhoto")
                stickers = obj.get("stickers", [])
                if not isinstance(stickers, list) or len(stickers) > 12:
                    raise ValueError("Too many stickers")
                sticker_ids = set()
                sticker_bytes = 0
                for sticker in stickers:
                    if not isinstance(sticker, dict) or set(sticker) != {"id", "data", "centerX", "centerY", "width", "rotation"}:
                        raise ValueError("Invalid sticker")
                    ident = sticker["id"]
                    if not isinstance(ident, str) or not re.fullmatch(r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}", ident) or ident.lower() in sticker_ids:
                        raise ValueError("Invalid sticker ID")
                    sticker_ids.add(ident.lower())
                    image = base64.b64decode(sticker["data"], validate=True)
                    sticker_bytes += len(image)
                    if not 0 < len(image) <= 500_000 or not image.startswith(b"\x89PNG\r\n\x1a\n"):
                        raise ValueError("Invalid sticker image")
                    for key, minimum, maximum in (("centerX", -100, 100), ("centerY", -100, 100),
                                                  ("width", 0.01, 10), ("rotation", -360, 360)):
                        value = sticker[key]
                        if type(value) not in (int, float) or not minimum <= value <= maximum:
                            raise ValueError("Invalid sticker placement")
                if sticker_bytes > 1_500_000:
                    raise ValueError("Stickers too large")
                if source not in ("a", "b", "together") or len(data) > MAX_BOARD_BYTES:
                    raise ValueError("Invalid source or drawing")
                if source in ("a", "b") and source.upper() != member[1]:
                    return self.reply(403, {"error": "Only the owner may publish personal art"})
                if type(expected) is not int or expected < 0 or type(height) not in (int, float) or not 300 <= height <= 2000:
                    raise ValueError("Invalid revision or drawing size")
                if not isinstance(color, str) or not re.fullmatch(r"#[0-9A-Fa-f]{6}", color):
                    raise ValueError("Invalid background color")
                if photo is not None:
                    if not isinstance(photo, dict) or not {"data", "zoom", "offsetX", "offsetY"} <= set(photo) or not set(photo) <= {"data", "zoom", "offsetX", "offsetY", "rotation"}:
                        raise ValueError("Invalid background photo")
                    image = base64.b64decode(photo["data"], validate=True)
                    if len(image) > 900_000 or not image.startswith(b"\xff\xd8"):
                        raise ValueError("Invalid background photo data")
                    if (type(photo["zoom"]) not in (int, float) or
                            not 0.1 <= photo["zoom"] <= 5 or
                            any(type(photo[k]) not in (int, float) or
                                not -100 <= photo[k] <= 100 for k in ("offsetX", "offsetY")) or
                            ("rotation" in photo and (type(photo["rotation"]) not in (int, float) or
                             not -360 <= photo["rotation"] <= 360))):
                        raise ValueError("Invalid photo placement")
            except (ValueError, KeyError, TypeError, binascii.Error, json.JSONDecodeError):
                return self.reply(400, {"error": "Invalid drawing request"})

            with lock, connect(db_path) as db:
                db.execute("BEGIN IMMEDIATE")
                board = board_update(db, member[0]) if source == "together" else None
                if board is not None and (type(obj.get("boardRevision")) is not int or obj["boardRevision"] != board["revision"]):
                    return self.reply(409, {"error": "The whiteboard changed. Refresh it and Apply again."})
                row = db.execute("SELECT revision FROM snapshots WHERE pair_id=? AND source=?",
                                 (member[0], source)).fetchone()
                current = row[0] if row else 0
                if current != expected:
                    return self.reply(409, {"error": "Someone applied a newer revision; your local drawing is preserved"})
                body = {"source": source, "revision": current + 1,
                        "author": member[1], "backgroundHex": color,
                        "backgroundPhoto": photo,
                        "stickers": stickers,
                        "drawingData": obj["drawingData"], "drawingHeight": height}
                try:
                    stored_body = media.store(body)
                except OSError:
                    return self.reply(507, {"error": "The server could not save the photo. Check available disk space."})
                db.execute("INSERT OR REPLACE INTO snapshots VALUES (?, ?, ?, ?)",
                           (member[0], source, current + 1, json.dumps(stored_body, separators=(",", ":"))))
                db.commit()
                db.execute("BEGIN IMMEDIATE")
                try:
                    media.prune(db)
                except OSError:
                    print("Media cleanup deferred until next server start.", flush=True)
                db.commit()
                state_changed.notify_all()
            self.event_detail = f" source={source} revision={current + 1}"
            if push_configured() or ntfy:
                threading.Thread(target=notify_partner,
                                 args=(db_path, member[0], member[1], source, current + 1),
                                 daemon=True).start()
            return self.reply(200, body, {"X-CoupleDraw-Media": "2"} if self.headers.get("X-CoupleDraw-Media") == "2" else None)

        def log_request(self, code="-", size="-"):
            # send_response calls this once per request, including generated errors.
            # Timing ends at the response headers; asynchronous ntfy/APNs delivery is separate.
            elapsed = (time.perf_counter() - getattr(self, "started_at", time.perf_counter())) * 1000
            route = urlsplit(self.path).path
            if route not in ("/v1/state", "/v1/device", "/v1/draft", "/v1/apply", "/v1/board/seed", "/v1/board/ops",
                             "/v1/media/ack", "/v1/media/request", "/v1/media/restore",
                             "/v1/pairing/create", "/v1/pairing/join", "/v1/pairing/status", "/v1/pairing/cancel"):
                route = "<other>"
            timestamp = datetime.now(timezone.utc).isoformat(timespec="milliseconds")
            print(f"{timestamp} client={getattr(self, 'client_role', '-')} "
                  f"peer={self.client_address[0]} {self.command} {route} "
                  f"status={code} duration_ms={elapsed:.1f}{getattr(self, 'event_detail', '')}",
                  flush=True)

        def log_message(self, format, *args):
            # Suppress the default raw request line, which can include secrets in query strings.
            pass

    httpd = SyncHTTPServer((host, port), Handler)
    print(f"CoupleDraw sync listening on {host}:{port}; use HTTP only on trusted local Wi-Fi, HTTPS elsewhere")
    print(f"Photos stored in {media.root}; migrated {migrated} inline photos, removed {removed} unused bytes")
    print("Create/Join pairing enabled: single-use codes expire in 5 minutes; private recovery lasts 24 hours")
    print("Temporary image delivery enabled: files are removed after both updated phones confirm local storage")
    if not push_configured():
        print("Partner push alerts disabled: set APNS_KEY_FILE, APNS_KEY_ID, APNS_TEAM_ID and APNS_TOPIC")
    if ntfy:
        print(f"ntfy alerts enabled via {ntfy}; keep each person's topic private")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nCoupleDraw sync stopped.")
    finally:
        httpd.server_close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("create-pair", "configure-ntfy", "compact", "serve"))
    parser.add_argument("--db", default="coupledraw.sqlite3")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--media-dir", help="Private photo directory (default: <db path>.media)")
    parser.add_argument("--custom-tokens", action="store_true",
                        help="Prompt privately for distinct A and B tokens when creating a pair")
    args = parser.parse_args()
    if args.command == "create-pair":
        try:
            pair(args.db, custom_tokens=args.custom_tokens)
        except (ValueError, getpass.GetPassWarning) as error:
            parser.error(str(error))
    elif args.command == "configure-ntfy":
        if args.custom_tokens:
            parser.error("--custom-tokens only works with create-pair")
        try:
            configure_ntfy(args.db)
        except ValueError as error:
            parser.error(str(error))
    elif args.command == "compact":
        if args.custom_tokens:
            parser.error("--custom-tokens only works with create-pair")
        migrated, removed = prepare_media(args.db, MediaFiles(args.db, args.media_dir), compact=True)
        print(f"Migrated {migrated} photos; removed {removed} unused media bytes; compacted SQLite.")
    else:
        if args.custom_tokens:
            parser.error("--custom-tokens only works with create-pair")
        serve(args.db, args.host, args.port, args.media_dir)
