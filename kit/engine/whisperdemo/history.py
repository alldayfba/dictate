#!/usr/bin/env python3
"""
WhisperShell — transcription history (SQLite).

Port of `TranscriptionHistory` from the monolith
(execution/whisper_flow.py, lines ~268-301). Storage path now resolves via
`paths.history_db_path()` instead of the repo-relative `.tmp/whisper/history.db`.

FIX F15: the monolith's schema already declares distinct `raw_text` /
`cleaned_text` columns, but the ONLY call site (whisper_flow.py:1549) passes
the already-cleaned string to BOTH params — `text = clean_transcript(text)`
happens first, then `_history.save(duration, text.strip(), text)` — so the
true pre-cleanup raw ASR output is never actually persisted. This port keeps
the two-column schema and makes the `save()` signature explicit
(`raw_text`, `cleaned_text` as separate required positional args) so the
caller (engine.py, main session) is forced to pass the true raw transcript
before cleanup is applied, not a second copy of the cleaned text.

No GUI imports. Emergency-save resilience (never lose a transcription if the
DB write fails) is the caller's responsibility in the monolith (a sibling
try/except around `_history.save()` writes an emergency .txt) — kept as a
documented caller contract here rather than duplicated, since this module
has no opinion on where an emergency file should live; `paths.state_dir()`
is the natural target for callers that want it.
"""

from __future__ import annotations

import sqlite3
from datetime import datetime
from pathlib import Path
from typing import Optional

from . import paths


class TranscriptionHistory:
    def __init__(self, db_path: Optional[Path] = None):
        self.db_path = db_path if db_path is not None else paths.history_db_path()
        with sqlite3.connect(str(self.db_path)) as conn:
            conn.execute("""CREATE TABLE IF NOT EXISTS transcriptions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp TEXT NOT NULL, duration_s REAL NOT NULL,
                raw_text TEXT NOT NULL, cleaned_text TEXT NOT NULL,
                word_count INTEGER NOT NULL, char_count INTEGER NOT NULL DEFAULT 0)""")
            conn.commit()

    def save(self, duration: float, raw_text: str, cleaned_text: str):
        """Persist one transcription. `raw_text` must be the true pre-cleanup
        ASR output; `cleaned_text` the post-`clean_transcript()`/dictionary
        result. Word/char counts are computed off `cleaned_text` (matches
        monolith behavior)."""
        with sqlite3.connect(str(self.db_path)) as conn:
            conn.execute(
                "INSERT INTO transcriptions (timestamp, duration_s, raw_text, cleaned_text, word_count, char_count) VALUES (?,?,?,?,?,?)",
                (datetime.now().isoformat(), duration, raw_text, cleaned_text, len(cleaned_text.split()), len(cleaned_text)))
            conn.commit()

    def list_recent(self, limit=20):
        with sqlite3.connect(str(self.db_path)) as conn:
            conn.row_factory = sqlite3.Row
            return [dict(r) for r in conn.execute("SELECT * FROM transcriptions ORDER BY id DESC LIMIT ?", (limit,)).fetchall()]

    def search(self, query: str, limit=20):
        with sqlite3.connect(str(self.db_path)) as conn:
            conn.row_factory = sqlite3.Row
            return [dict(r) for r in conn.execute("SELECT * FROM transcriptions WHERE cleaned_text LIKE ? ORDER BY id DESC LIMIT ?", (f"%{query}%", limit)).fetchall()]

    def stats(self):
        """Lightweight stats for the menubar: total_count, total_chars, today_count.

        NOTE (semantic decision): the monolith's `stats()` returned
        {total, words, minutes}. Per this port's spec, `stats()` is
        repointed to the menubar shape below. The original shape is
        preserved as `full_stats()` so nothing is lost for any future CLI
        parity work.
        """
        today_prefix = datetime.now().strftime("%Y-%m-%d")
        with sqlite3.connect(str(self.db_path)) as conn:
            total_count, total_chars = conn.execute(
                "SELECT COUNT(*), COALESCE(SUM(char_count),0) FROM transcriptions"
            ).fetchone()
            (today_count,) = conn.execute(
                "SELECT COUNT(*) FROM transcriptions WHERE timestamp LIKE ?",
                (f"{today_prefix}%",),
            ).fetchone()
            return {
                "total_count": total_count,
                "total_chars": total_chars,
                "today_count": today_count,
            }

    def full_stats(self):
        """Original monolith stats() shape: total count, total words, total minutes."""
        with sqlite3.connect(str(self.db_path)) as conn:
            r = conn.execute("SELECT COUNT(*), COALESCE(SUM(word_count),0), COALESCE(SUM(duration_s),0) FROM transcriptions").fetchone()
            return {"total": r[0], "words": r[1], "minutes": round(r[2] / 60, 1)}
