"""Lightweight persistent memory for Sakura Chat.

SQLite (stdlib sqlite3) holding, per anonymous user:
  - a compact JSON memory document (profile facts, preferences, projects, summary)
  - interaction counters and timestamps
  - completed text transcript turns, used later for memory extraction

Nothing in this module runs in the real-time audio path: all DB work goes
through asyncio.to_thread, and extraction is a separate Gemini text call that
callers fire as a background task.
"""

import asyncio
import json
import logging
import secrets
import sqlite3
from collections import defaultdict
from contextlib import contextmanager
from datetime import datetime, timezone
from os import environ
from pathlib import Path

log = logging.getLogger("sakura.memory")

# ---------------------------------------------------------------- constants
DB_PATH = Path(environ.get("SAKURA_DB_PATH", Path(__file__).parent / "sakura.db"))
MEMORY_MODEL = environ.get("SAKURA_MEMORY_MODEL", "gemini-2.5-flash")

MAX_FACTS = int(environ.get("SAKURA_MAX_FACTS", 15))
MAX_PREFERENCES = int(environ.get("SAKURA_MAX_PREFERENCES", 10))
MAX_PROJECTS = int(environ.get("SAKURA_MAX_PROJECTS", 8))
MAX_SUMMARY_CHARS = int(environ.get("SAKURA_MAX_SUMMARY_CHARS", 600))
UPDATE_TURN_THRESHOLD = int(environ.get("SAKURA_UPDATE_TURN_THRESHOLD", 12))

MAX_ITEM_CHARS = 200           # single fact/preference/project entry
MIN_TURNS_FOR_UPDATE = 2       # don't bother extracting from less than this
MAX_TURNS_PER_EXTRACTION = 80  # bound the extraction prompt
MEMORY_SECTION_MAX_CHARS = 4000  # ~1k tokens injected into the system prompt

EMPTY_MEMORY = {
    "profile": {"preferred_name": None, "facts": [], "preferences": [], "projects": []},
    "relationship_summary": "",
}

_locks: dict[tuple, asyncio.Lock] = defaultdict(asyncio.Lock)  # per (db, user) update lock


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


# ---------------------------------------------------------------- identity
def new_uid() -> str:
    return secrets.token_hex(16)


def valid_uid(uid) -> bool:
    return isinstance(uid, str) and len(uid) == 32 and all(c in "0123456789abcdef" for c in uid)


# ---------------------------------------------------------------- db plumbing
@contextmanager
def _connect(db_path):
    """One transaction per connection, always closed afterwards."""
    con = sqlite3.connect(db_path, timeout=5)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA journal_mode=WAL")
    con.execute("PRAGMA foreign_keys=ON")
    try:
        with con:
            yield con
    finally:
        con.close()


SCHEMA_VERSION = 1


def init_db(db_path=DB_PATH):
    """Create tables; safe to call on every startup (lightweight migration hook)."""
    with _connect(db_path) as con:
        con.executescript(
            """
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS users (
                user_id TEXT PRIMARY KEY,
                memory TEXT NOT NULL,
                interaction_count INTEGER NOT NULL DEFAULT 0,
                first_seen_at TEXT NOT NULL,
                last_seen_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS sessions (
                session_id TEXT PRIMARY KEY,
                user_id TEXT NOT NULL,
                started_at TEXT NOT NULL,
                ended_at TEXT
            );
            CREATE TABLE IF NOT EXISTS turns (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL,
                user_id TEXT NOT NULL,
                role TEXT NOT NULL CHECK (role IN ('user', 'sakura')),
                text TEXT NOT NULL,
                created_at TEXT NOT NULL,
                processed INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS turns_unprocessed ON turns (user_id, processed);
            """
        )
        row = con.execute("SELECT value FROM meta WHERE key='schema_version'").fetchone()
        if row is None:
            con.execute("INSERT INTO meta VALUES ('schema_version', ?)", (str(SCHEMA_VERSION),))
        # future migrations: compare int(row['value']) to SCHEMA_VERSION and ALTER here


def _get_or_create(con, uid):
    row = con.execute("SELECT * FROM users WHERE user_id=?", (uid,)).fetchone()
    if row is None:
        now = _now()
        con.execute(
            "INSERT INTO users VALUES (?,?,?,?,?,?)",
            (uid, json.dumps(EMPTY_MEMORY), 0, now, now, now),
        )
        row = con.execute("SELECT * FROM users WHERE user_id=?", (uid,)).fetchone()
    return row


# ---------------------------------------------------------------- async repository
async def touch_user(uid, db_path=DB_PATH) -> dict:
    """Get-or-create the user, bump interaction count, return the row as a dict."""

    def work():
        with _connect(db_path) as con:
            _get_or_create(con, uid)
            con.execute(
                "UPDATE users SET interaction_count=interaction_count+1, last_seen_at=? WHERE user_id=?",
                (_now(), uid),
            )
            return dict(con.execute("SELECT * FROM users WHERE user_id=?", (uid,)).fetchone())

    return await asyncio.to_thread(work)


async def get_view(uid, db_path=DB_PATH) -> dict:
    """Read-only view of a user's memory (no row is created for unknown users)."""

    def work():
        with _connect(db_path) as con:
            row = con.execute("SELECT * FROM users WHERE user_id=?", (uid,)).fetchone()
        if row is None:
            return {"memory": EMPTY_MEMORY, "interaction_count": 0,
                    "first_seen_at": None, "last_seen_at": None, "updated_at": None}
        return {"memory": json.loads(row["memory"]),
                "interaction_count": row["interaction_count"],
                "first_seen_at": row["first_seen_at"],
                "last_seen_at": row["last_seen_at"],
                "updated_at": row["updated_at"]}

    return await asyncio.to_thread(work)


async def save_memory(uid, doc, db_path=DB_PATH):
    """Replace a user's memory document (used by the edit endpoint)."""
    doc = bound_memory(doc)

    def work():
        with _connect(db_path) as con:
            _get_or_create(con, uid)
            con.execute("UPDATE users SET memory=?, updated_at=? WHERE user_id=?",
                        (json.dumps(doc), _now(), uid))

    await asyncio.to_thread(work)


async def clear_user(uid, db_path=DB_PATH):
    """Delete this user's memory, sessions and transcripts. Nobody else's."""

    def work():
        with _connect(db_path) as con:
            con.execute("DELETE FROM turns WHERE user_id=?", (uid,))
            con.execute("DELETE FROM sessions WHERE user_id=?", (uid,))
            con.execute("DELETE FROM users WHERE user_id=?", (uid,))

    await asyncio.to_thread(work)


async def start_session(session_id, uid, db_path=DB_PATH):
    def work():
        with _connect(db_path) as con:
            con.execute("INSERT OR IGNORE INTO sessions VALUES (?,?,?,NULL)", (session_id, uid, _now()))

    await asyncio.to_thread(work)


async def end_session(session_id, db_path=DB_PATH):
    def work():
        with _connect(db_path) as con:
            con.execute("UPDATE sessions SET ended_at=? WHERE session_id=?", (_now(), session_id))

    await asyncio.to_thread(work)


async def add_turn(session_id, uid, role, text, db_path=DB_PATH):
    def work():
        with _connect(db_path) as con:
            con.execute(
                "INSERT INTO turns (session_id, user_id, role, text, created_at) VALUES (?,?,?,?,?)",
                (session_id, uid, role, text, _now()),
            )

    await asyncio.to_thread(work)


# ---------------------------------------------------------------- bounding
def _clip_list(value, max_items):
    if not isinstance(value, list):
        return []
    return [str(v)[:MAX_ITEM_CHARS] for v in value if str(v).strip()][:max_items]


def bound_memory(doc) -> dict:
    """Coerce an arbitrary dict into a valid, size-bounded memory document."""
    if not isinstance(doc, dict):
        return json.loads(json.dumps(EMPTY_MEMORY))
    profile = doc.get("profile") if isinstance(doc.get("profile"), dict) else {}
    name = profile.get("preferred_name")
    return {
        "profile": {
            "preferred_name": str(name)[:80] if name else None,
            "facts": _clip_list(profile.get("facts"), MAX_FACTS),
            "preferences": _clip_list(profile.get("preferences"), MAX_PREFERENCES),
            "projects": _clip_list(profile.get("projects"), MAX_PROJECTS),
        },
        "relationship_summary": str(doc.get("relationship_summary") or "")[:MAX_SUMMARY_CHARS],
    }


# ---------------------------------------------------------------- formatting
def format_memory_section(user_row) -> str:
    """Turn a users-table row (dict) into a plain-text block for the system prompt.

    Returns "" when there is nothing worth injecting (true first meeting).
    """
    mem = bound_memory(json.loads(user_row["memory"]) if isinstance(user_row.get("memory"), str)
                       else user_row.get("memory") or {})
    p = mem["profile"]
    has_content = p["preferred_name"] or p["facts"] or p["preferences"] or p["projects"] or mem["relationship_summary"]
    past_chats = max(0, int(user_row.get("interaction_count") or 1) - 1)
    if not has_content and past_chats == 0:
        return ""

    lines = [
        "=== YOUR MEMORY OF THIS FRIEND (from past chats) ===",
        "These notes may be incomplete. NEVER invent details that are not written here —",
        "if something isn't in these notes you simply don't remember it; say so naturally.",
    ]
    if past_chats > 0:
        lines.append(f"You have chatted {past_chats} time(s) before (first met {str(user_row.get('first_seen_at'))[:10]}). "
                     "Do NOT introduce yourself as if this were a first meeting.")
    if p["preferred_name"]:
        lines.append(f"They like to be called: {p['preferred_name']}")
    if p["facts"]:
        lines.append("Facts they told you: " + "; ".join(p["facts"]))
    if p["preferences"]:
        lines.append("Their preferences: " + "; ".join(p["preferences"]))
    if p["projects"]:
        lines.append("Their projects / recurring topics: " + "; ".join(p["projects"]))
    if mem["relationship_summary"]:
        lines.append("Your relationship so far: " + mem["relationship_summary"])
    lines.append("=== END MEMORY ===")
    return "\n".join(lines)[:MEMORY_SECTION_MAX_CHARS]


# ---------------------------------------------------------------- extraction
_EXTRACT_PROMPT = """You maintain the long-term memory document that a voice companion called Sakura
keeps about one specific user. Merge the new conversation turns into the memory.

Return ONLY a JSON object, no other text, with exactly this shape:
{{"profile": {{"preferred_name": <string or null>, "facts": [<strings>], "preferences": [<strings>], "projects": [<strings>]}}, "relationship_summary": <string>}}

KEEP only:
- facts the user explicitly stated about themselves
- durable preferences
- recurring projects, people or topics likely to matter in later chats
- commitments or unresolved threads worth following up on

DO NOT keep:
- guesses or inferred personal attributes
- claims Sakura made that the user did not confirm
- transient small talk, duplicates, or details contradicted by newer statements (keep the newest)
- sensitive information that is not clearly useful for future conversation

Limits: at most {max_facts} facts, {max_prefs} preferences, {max_projects} projects, each under 25 words.
relationship_summary: under {summary_words} words, written as Sakura's own brief diary-style notes.
Output the COMPLETE replacement memory — restate old items you are keeping.

CURRENT MEMORY:
{old}

NEW CONVERSATION TURNS:
{turns}
"""


def make_extractor(client):
    """Build the default extractor around a google-genai client."""

    async def extract(old_memory: dict, turns: list[dict]) -> dict:
        convo = "\n".join(f"{t['role']}: {t['text']}" for t in turns)
        prompt = _EXTRACT_PROMPT.format(
            max_facts=MAX_FACTS, max_prefs=MAX_PREFERENCES, max_projects=MAX_PROJECTS,
            summary_words=MAX_SUMMARY_CHARS // 6,
            old=json.dumps(old_memory, ensure_ascii=False),
            turns=convo,
        )
        resp = await client.aio.models.generate_content(
            model=MEMORY_MODEL,
            contents=prompt,
            config={"response_mime_type": "application/json", "temperature": 0.2},
        )
        text = (resp.text or "").strip().removeprefix("```json").removeprefix("```").removesuffix("```")
        return json.loads(text)

    return extract


async def update_user_memory(uid, extractor, db_path=DB_PATH) -> bool:
    """Fold unprocessed transcript turns into the user's memory document.

    Safe to call repeatedly/concurrently: a per-user lock plus the `processed`
    marker guarantee each turn is incorporated at most once. On any extraction
    failure the existing memory is left untouched.
    """
    async with _locks[(str(db_path), uid)]:
        def fetch():
            with _connect(db_path) as con:
                user = con.execute("SELECT * FROM users WHERE user_id=?", (uid,)).fetchone()
                turns = con.execute(
                    "SELECT id, role, text FROM turns WHERE user_id=? AND processed=0 "
                    "ORDER BY id LIMIT ?", (uid, MAX_TURNS_PER_EXTRACTION),
                ).fetchall()
            return (dict(user) if user else None), [dict(t) for t in turns]

        user, turns = await asyncio.to_thread(fetch)
        if user is None or len(turns) < MIN_TURNS_FOR_UPDATE:
            return False

        old = bound_memory(json.loads(user["memory"]))
        try:
            new_doc = bound_memory(await extractor(old, turns))
        except Exception as e:
            log.warning("memory extraction failed for user %s…: %s", uid[:8], e)
            return False

        turn_ids = [t["id"] for t in turns]

        def commit():
            with _connect(db_path) as con:  # one transaction: replace memory + mark turns
                con.execute("UPDATE users SET memory=?, updated_at=? WHERE user_id=?",
                            (json.dumps(new_doc, ensure_ascii=False), _now(), uid))
                con.executemany("UPDATE turns SET processed=1 WHERE id=?",
                                [(i,) for i in turn_ids])

        await asyncio.to_thread(commit)
        log.info("memory updated for user %s… (%d turns folded in)", uid[:8], len(turns))
        return True
