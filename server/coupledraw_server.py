#!/usr/bin/env python3
"""Small private pairing/snapshot service. Use LAN HTTP only for local tests.

create-pair generates or prompts for two independent bearer tokens. The service stores only editable
snapshots; iPhones render their own wallpaper sizes from the selected source.
"""
import argparse
import base64
import binascii
import getpass
import hashlib
import json
import math
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
from pathlib import Path
from urllib.parse import urlsplit
from urllib.request import Request, urlopen

MAX_BODY = 8_000_000
MAX_BOARD_BYTES = 3_000_000
MAX_STROKES = 3000
lock = threading.RLock()
state_changed = threading.Condition(lock)


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

    def restore_image(self, item):
        if item is not None and "mediaID" in item:
            image = self.path(item["mediaID"]).read_bytes()
            if hashlib.sha256(image).hexdigest() != item["mediaID"]:
                raise ValueError("Stored media is damaged")
            result = {key: value for key, value in item.items() if key != "mediaID"}
            result["data"] = base64.b64encode(image).decode()
            return result
        return item

    def restore(self, body):
        if body is None:
            return None
        result = dict(body)
        result["backgroundPhoto"] = self.restore_image(body.get("backgroundPhoto"))
        if "stickers" in body:
            result["stickers"] = [self.restore_image(item) for item in body["stickers"]]
        return result

    def prune(self, db):
        # Call inside BEGIN IMMEDIATE. Readers hydrate files within the same
        # SQLite lock, so an in-flight response cannot lose its referenced JPEG.
        referenced = set()
        for (raw,) in db.execute("SELECT body FROM snapshots UNION ALL SELECT body FROM shared_base"):
            body = json.loads(raw) or {}
            for item in [body.get("backgroundPhoto"), *body.get("stickers", [])]:
                if item and "mediaID" in item:
                    self.path(item["mediaID"])  # Validate before deleting anything.
                    referenced.add(item["mediaID"])
        removed = 0
        for file in self.root.glob("*.image"):
            if re.fullmatch(r"[0-9a-f]{64}", file.stem) and file.stem not in referenced:
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


def connect(path):
    db = sqlite3.connect(path, timeout=10)
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
    db.commit()
    return db


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
                type(height) not in (int, float) or not math.isfinite(height) or not 300 <= height <= 2000):
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
                         if part.startswith("wait=") and part[5:].isdigit() and
                         1 <= int(part[5:]) <= 25), 0)
            deadline = time.monotonic() + wait
            def known_versions(header):
                result = {}
                for pair in self.headers.get(header, "").split(","):
                    key, separator, value = pair.partition(":")
                    if separator and value.isdigit() and len(key) <= 16:
                        result[key] = int(value)
                return result

            known_snapshots = known_versions("X-CoupleDraw-Snapshots")
            known_drafts = known_versions("X-CoupleDraw-Drafts")
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
                        marker = json.dumps([member[1], push, topic, ntfy,
                                         [(source, revision) for source, revision, _ in rows],
                                         [(role, revision) for role, revision, _, _ in drafts],
                                         board["revision"] if board else None],
                                        separators=(",", ":")).encode()
                        etag = '"' + hashlib.sha256(marker).hexdigest()[:24] + '"'
                        remaining = deadline - time.monotonic()
                        if self.headers.get("If-None-Match") != etag:
                            try:
                                changed_snapshots = [media.restore(json.loads(body)) for source, revision, body in rows
                                                     if known_snapshots.get(source) != revision]
                                hydrated_base = None if self.headers.get("X-CoupleDraw-Base-Known") == "1" else media.restore(json.loads(base_row[0]))
                            except (OSError, ValueError):
                                return self.reply(503, {"error": "A stored photo is unavailable. Restore the server media backup or re-apply the photo from a phone."})
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
                                    "mediaProtocol": 1,
                                    "boardProtocol": 1, "boardSeedTag": seed_tag,
                                    "board": board if board and board["revision"] != self.board_since() else None,
                                    "sharedBase": None if self.headers.get("X-CoupleDraw-Base-Known") == "1"
                                    else hydrated_base,
                                    "draftRevisions": {role: revision for role, revision, _, _ in drafts},
                                    "drafts": changed_drafts},
                              {"ETag": etag, "X-CoupleDraw-Long-Poll": "1"})

        def board_since(self):
            raw = self.headers.get("X-CoupleDraw-Board", "")
            return int(raw) if raw.isdigit() and len(raw) < 12 else None

        def edit_board(self, member, seed=False):
            try:
                size = int(self.headers.get("Content-Length", "0"))
                if not 0 < size <= MAX_BODY:
                    raise ValueError("Board request too large")
                obj = json.loads(self.rfile.read(size))
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
            member = self.member()
            if not member:
                return self.reply(401, {"error": "Invalid pairing token"})
            if self.path in ("/v1/board/seed", "/v1/board/ops"):
                return self.edit_board(member, seed=self.path.endswith("/seed"))
            if self.path == "/v1/device":
                try:
                    size = int(self.headers.get("Content-Length", "0"))
                    if not 0 < size <= 512:
                        raise ValueError("Invalid body size")
                    data = json.loads(self.rfile.read(size))
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
                    size = int(self.headers.get("Content-Length", "0"))
                    if not 0 < size <= 1_500_000:
                        raise ValueError("Draft too large")
                    obj = json.loads(self.rfile.read(size))
                    data = obj["drawingData"]
                    height = obj["drawingHeight"]
                    if (not isinstance(data, str) or len(base64.b64decode(data, validate=True)) > 1_000_000 or
                            type(height) not in (int, float) or not math.isfinite(height) or
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
                size = int(self.headers.get("Content-Length", "0"))
                if not 0 < size <= MAX_BODY:
                    raise ValueError("Drawing too large")
                obj = json.loads(self.rfile.read(size))
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
                    if not isinstance(ident, str) or not re.fullmatch(r"[0-9A-Fa-f-]{36}", ident) or ident.lower() in sticker_ids:
                        raise ValueError("Invalid sticker ID")
                    sticker_ids.add(ident.lower())
                    image = base64.b64decode(sticker["data"], validate=True)
                    sticker_bytes += len(image)
                    if not 0 < len(image) <= 500_000 or not image.startswith(b"\x89PNG\r\n\x1a\n"):
                        raise ValueError("Invalid sticker image")
                    for key, minimum, maximum in (("centerX", -100, 100), ("centerY", -100, 100),
                                                  ("width", 0.01, 10), ("rotation", -360, 360)):
                        value = sticker[key]
                        if type(value) not in (int, float) or not math.isfinite(value) or not minimum <= value <= maximum:
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
                    if (type(photo["zoom"]) not in (int, float) or not math.isfinite(photo["zoom"]) or
                            not 0.1 <= photo["zoom"] <= 5 or
                            any(type(photo[k]) not in (int, float) or not math.isfinite(photo[k]) or
                                not -100 <= photo[k] <= 100 for k in ("offsetX", "offsetY")) or
                            ("rotation" in photo and (type(photo["rotation"]) not in (int, float) or
                             not math.isfinite(photo["rotation"]) or not -360 <= photo["rotation"] <= 360))):
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
            return self.reply(200, body)

        def log_request(self, code="-", size="-"):
            # send_response calls this once per request, including generated errors.
            # Timing ends at the response headers; asynchronous ntfy/APNs delivery is separate.
            elapsed = (time.perf_counter() - getattr(self, "started_at", time.perf_counter())) * 1000
            route = urlsplit(self.path).path
            if route not in ("/v1/state", "/v1/device", "/v1/draft", "/v1/apply", "/v1/board/seed", "/v1/board/ops"):
                route = "<other>"
            timestamp = datetime.now(timezone.utc).isoformat(timespec="milliseconds")
            print(f"{timestamp} client={getattr(self, 'client_role', '-')} "
                  f"peer={self.client_address[0]} {self.command} {route} "
                  f"status={code} duration_ms={elapsed:.1f}{getattr(self, 'event_detail', '')}",
                  flush=True)

        def log_message(self, format, *args):
            # Suppress the default raw request line, which can include secrets in query strings.
            pass

    httpd = ThreadingHTTPServer((host, port), Handler)
    print(f"CoupleDraw sync listening on {host}:{port}; use HTTP only on trusted local Wi-Fi, HTTPS elsewhere")
    print(f"Photos stored in {media.root}; migrated {migrated} inline photos, removed {removed} unused bytes")
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
