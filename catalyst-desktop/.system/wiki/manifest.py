"""The manifest: change-detection state only (spec sec.4).

Stores no tags, no frontmatter properties, no content. Those live in the
markdown and are queried through Obsidian. The manifest answers exactly one
question: does the tagger need to run on this file?

SQLite is used for transactional batching. A run that dies partway through
must not leave half-written state.
"""
from __future__ import annotations

import datetime as _dt
import sqlite3
from contextlib import contextmanager
from pathlib import Path
from typing import Dict, Iterable, List, Optional

from . import config

SCHEMA_VERSION = 3

_SCHEMA = """
CREATE TABLE IF NOT EXISTS notes (
    path        TEXT PRIMARY KEY,
    mtime       INTEGER,         -- last-seen disk mtime; hash pre-filter (sec.3)
    file_bytes  INTEGER,         -- last-seen file size; second half of the pre-filter
    body_hash   TEXT NOT NULL,   -- YAML frontmatter stripped before hashing
    body_bytes  INTEGER,
    body_lines  INTEGER,
    status      TEXT,            -- pending | tagged | failed | deleted
    tag_attempts INTEGER DEFAULT 0,  -- consecutive tagger failures; caps retries
    tagged_hash TEXT,            -- body_hash as of the last tagger pass
    tagged_at   TEXT,
    seen_at     TEXT
);

CREATE INDEX IF NOT EXISTS idx_notes_hash ON notes(body_hash);

CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value TEXT
);
"""


def connect(path: Optional[Path] = None) -> sqlite3.Connection:
    target = Path(path) if path else config.MANIFEST
    target.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(target), timeout=30.0)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys=ON")

    # WAL is preferred but requires shared-memory support the filesystem may not
    # have. It fails outright on FUSE-style mounts, which includes the Google
    # Drive virtual mount -- so falling back rather than crashing matters if the
    # vault ever lives there. TRUNCATE also leaves no persistent -wal/-shm
    # sidecars, which is one fewer thing for sec.2's exclusions to cover.
    for mode in ("WAL", "TRUNCATE", "DELETE"):
        try:
            conn.execute("PRAGMA journal_mode=%s" % mode).fetchone()
            conn.execute("PRAGMA synchronous=%s" % ("NORMAL" if mode == "WAL" else "FULL"))
            # Prove it actually works; PRAGMA alone can succeed where I/O fails.
            conn.execute("CREATE TABLE IF NOT EXISTS _probe(x)")
            conn.execute("DROP TABLE IF EXISTS _probe")
            conn.commit()
            return conn
        except sqlite3.OperationalError:
            continue
    raise sqlite3.OperationalError(
        "could not open %s in any journal mode -- is the filesystem writable?" % target
    )


def _columns(conn: sqlite3.Connection, table: str) -> set:
    return {r[1] for r in conn.execute("PRAGMA table_info(%s)" % table)}


# Columns added after v1. `CREATE TABLE IF NOT EXISTS` is a no-op on an existing
# table, so without this an upgraded install keeps the old columns while `meta`
# cheerfully reports the new schema version -- and the first write using a new
# column fails at runtime. Additive only; SQLite's ALTER is limited and the
# manifest is disposable, so anything more invasive should just force a rebuild.
_MIGRATIONS = (
    ("file_bytes", "ALTER TABLE notes ADD COLUMN file_bytes INTEGER"),
    ("tag_attempts", "ALTER TABLE notes ADD COLUMN tag_attempts INTEGER DEFAULT 0"),
)


def init(conn: sqlite3.Connection) -> None:
    conn.executescript(_SCHEMA)

    existing = _columns(conn, "notes")
    applied = []
    for column, ddl in _MIGRATIONS:
        if column not in existing:
            conn.execute(ddl)
            applied.append(column)

    if applied:
        # A file predating these columns has no baseline for them, so its
        # pre-filter comparison would spuriously match. Clearing mtime forces one
        # full re-hash pass, which is cheap and strictly safer than guessing.
        conn.execute("UPDATE notes SET mtime = NULL")
        set_meta(conn, "last_migration", ",".join(applied))

    set_meta(conn, "schema_version", str(SCHEMA_VERSION))
    conn.commit()
    return applied


# --- meta -------------------------------------------------------------------

def get_meta(conn: sqlite3.Connection, key: str) -> Optional[str]:
    row = conn.execute("SELECT value FROM meta WHERE key = ?", (key,)).fetchone()
    return row["value"] if row else None


def set_meta(conn: sqlite3.Connection, key: str, value: str) -> None:
    conn.execute(
        "INSERT INTO meta(key, value) VALUES(?, ?) "
        "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        (key, value),
    )


def days_since_meta(conn: sqlite3.Connection, key: str) -> Optional[float]:
    raw = get_meta(conn, key)
    if not raw:
        return None
    try:
        then = _dt.datetime.fromisoformat(raw)
    except ValueError:
        return None
    return (_dt.datetime.now() - then).total_seconds() / 86400.0


# --- reads ------------------------------------------------------------------

def load_all(conn: sqlite3.Connection) -> Dict[str, sqlite3.Row]:
    """Whole manifest keyed by path.

    Loading it all is deliberate: the classifier needs a hash->path reverse view
    and a full path set anyway, and at vault scale this is a few hundred KB.
    """
    return {r["path"]: r for r in conn.execute("SELECT * FROM notes")}


def pending(conn: sqlite3.Connection, limit: int) -> List[sqlite3.Row]:
    return list(conn.execute(
        "SELECT * FROM notes WHERE status = 'pending' ORDER BY seen_at LIMIT ?", (limit,)
    ))


def counts_by_status(conn: sqlite3.Connection) -> Dict[str, int]:
    return {r["status"] or "unknown": r["n"] for r in conn.execute(
        "SELECT status, COUNT(*) AS n FROM notes GROUP BY status")}


# --- writes -----------------------------------------------------------------

@contextmanager
def transaction(conn: sqlite3.Connection):
    """One atomic unit for an entire run (spec sec.4 step 7).

    Changes are accumulated by the caller and applied here in a single
    transaction. Note this intentionally does NOT hold a write lock across the
    LLM calls in step 4 -- the spec's requirement is atomicity, and buffering
    then committing achieves that without a minutes-long lock.
    """
    try:
        conn.execute("BEGIN IMMEDIATE")
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise


def upsert(conn: sqlite3.Connection, row: dict) -> None:
    conn.execute(
        """
        INSERT INTO notes (path, mtime, file_bytes, body_hash, body_bytes, body_lines,
                           status, tagged_hash, tagged_at, seen_at)
        VALUES (:path, :mtime, :file_bytes, :body_hash, :body_bytes, :body_lines,
                :status, :tagged_hash, :tagged_at, :seen_at)
        ON CONFLICT(path) DO UPDATE SET
            mtime       = excluded.mtime,
            file_bytes  = excluded.file_bytes,
            body_hash   = excluded.body_hash,
            body_bytes  = excluded.body_bytes,
            body_lines  = excluded.body_lines,
            status      = excluded.status,
            tagged_hash = COALESCE(excluded.tagged_hash, notes.tagged_hash),
            tagged_at   = COALESCE(excluded.tagged_at, notes.tagged_at),
            seen_at     = excluded.seen_at
        """,
        {
            "path": row["path"],
            "mtime": row.get("mtime"),
            "file_bytes": row.get("file_bytes"),
            "body_hash": row["body_hash"],
            "body_bytes": row.get("body_bytes"),
            "body_lines": row.get("body_lines"),
            "status": row.get("status"),
            "tagged_hash": row.get("tagged_hash"),
            "tagged_at": row.get("tagged_at"),
            "seen_at": row.get("seen_at"),
        },
    )


def repoint(conn: sqlite3.Connection, old_path: str, new_path: str, mtime: int,
            file_bytes: int, seen_at: str) -> None:
    """Case 2: a move. Update the path in place; no LLM call, tagging state kept."""
    conn.execute(
        "UPDATE notes SET path = ?, mtime = ?, file_bytes = ?, seen_at = ?, status = "
        "CASE WHEN status = 'deleted' THEN 'tagged' ELSE status END WHERE path = ?",
        (new_path, mtime, file_bytes, seen_at, old_path),
    )


def stamp_seen(conn: sqlite3.Connection, paths: Iterable[str], seen_at: str) -> None:
    conn.executemany("UPDATE notes SET seen_at = ? WHERE path = ?",
                     [(seen_at, p) for p in paths])


def touch(conn: sqlite3.Connection, path: str, mtime: int, file_bytes: int,
          seen_at: str) -> None:
    conn.execute("UPDATE notes SET mtime = ?, file_bytes = ?, seen_at = ? WHERE path = ?",
                 (mtime, file_bytes, seen_at, path))


def mark_tagged(conn: sqlite3.Connection, path: str, body_hash: str, when: str) -> None:
    conn.execute(
        "UPDATE notes SET status = 'tagged', tagged_hash = ?, tagged_at = ?, "
        "tag_attempts = 0 WHERE path = ?",
        (body_hash, when, path),
    )


def record_tag_failure(conn: sqlite3.Connection, path: str, max_attempts: int) -> None:
    """Count a failed tagging attempt, and give up after `max_attempts`.

    Without a cap an unattended job retries a permanently-broken file every run
    forever -- an LLM call every 15 minutes, indefinitely, for nothing. `failed`
    is terminal until the file changes or `retry-failed` resets it.
    """
    conn.execute(
        "UPDATE notes SET tag_attempts = COALESCE(tag_attempts, 0) + 1, "
        "status = CASE WHEN COALESCE(tag_attempts, 0) + 1 >= ? THEN 'failed' "
        "ELSE 'pending' END WHERE path = ?",
        (max_attempts, path),
    )


def reset_failed(conn: sqlite3.Connection) -> int:
    cur = conn.execute(
        "UPDATE notes SET status = 'pending', tag_attempts = 0 WHERE status = 'failed'")
    return cur.rowcount


def sweep_deleted(conn: sqlite3.Connection, run_start: str) -> List[str]:
    """Case 6. Anything not observed this run is gone.

    Runs inside the same transaction as the rest of the run: if the run dies
    before commit nothing is stamped and nothing is marked deleted, so the next
    run re-derives everything from disk.
    """
    rows = conn.execute(
        "SELECT path FROM notes WHERE (seen_at IS NULL OR seen_at < ?) AND status != 'deleted'",
        (run_start,),
    ).fetchall()
    paths = [r["path"] for r in rows]
    if paths:
        conn.executemany(
            "UPDATE notes SET status = 'deleted', seen_at = ? WHERE path = ?",
            [(run_start, p) for p in paths],
        )
    return paths


def hard_delete_expired(conn: sqlite3.Connection, grace_days: int) -> List[str]:
    cutoff = (_dt.datetime.now() - _dt.timedelta(days=grace_days)).isoformat()
    rows = conn.execute(
        "SELECT path FROM notes WHERE status = 'deleted' AND seen_at < ?", (cutoff,)
    ).fetchall()
    paths = [r["path"] for r in rows]
    if paths:
        conn.executemany("DELETE FROM notes WHERE path = ?", [(p,) for p in paths])
    return paths
