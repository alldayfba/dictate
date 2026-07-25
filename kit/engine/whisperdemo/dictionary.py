#!/usr/bin/env python3
"""
WhisperShell — custom dictionary (learns user corrections).

VERBATIM PORT of `WhisperDictionary` from the monolith
(execution/whisper_flow.py, lines ~160-254). Only change: default storage
path now resolves via `paths.dictionary_path()`
(~/Library/Application Support/WhisperFlow/dictionary.json) instead of the
repo-relative `.tmp/whisper/dictionary.json`. No macOS/GUI imports.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import time
from pathlib import Path
from typing import Optional

from . import paths


class WhisperDictionary:
    """Persistent dictionary that learns user corrections.

    Stores word mappings in JSON. Used for:
    1. Hotwords prompt for Whisper (improves recognition of known names/terms)
    2. Post-transcription find/replace for misspellings Whisper consistently gets wrong
    """

    # Common English words that should NEVER be auto-correction sources or targets
    PROTECTED_WORDS = frozenset({
        "i", "a", "an", "the", "it", "is", "in", "to", "do", "we", "he",
        "me", "be", "so", "no", "go", "if", "or", "on", "at", "my", "of",
        "up", "as", "by", "am", "us", "and", "but", "for", "not", "you",
        "all", "can", "had", "her", "was", "one", "our", "out", "are",
        "has", "his", "how", "its", "may", "new", "now", "old", "see",
        "way", "who", "did", "get", "let", "say", "she", "too", "use",
        "bro", "dude", "like", "just", "that", "this", "with", "have",
        "from", "they", "been", "said", "each", "what", "then", "them",
        "will", "when", "make", "time", "very", "your", "here", "know",
        "sell", "self", "cloud", "more", "some", "also", "than", "into",
        "over", "such", "take", "year", "come", "could", "good", "most",
        "need", "does", "back", "work", "only", "well", "about", "would",
    })

    def __init__(self, path: Optional[Path] = None):
        self.path = path if path is not None else paths.dictionary_path()
        self.corrections: dict[str, str] = {}  # wrong → right (case-insensitive keys)
        self.hotwords: list[str] = []  # known proper nouns/terms
        self._load()

    def _load(self):
        if self.path.exists():
            try:
                data = json.loads(self.path.read_text())
                self.corrections = data.get("corrections", {})
                self.hotwords = data.get("hotwords", [])
            except (json.JSONDecodeError, KeyError):
                # Corruption recovery: back up the bad file, start fresh.
                try:
                    backup = paths.backups_dir() / f"dictionary_corrupt_{int(time.time())}.json"
                    shutil.copy2(self.path, backup)
                    print(f"[WhisperFlow] Corrupt dictionary backed up to {backup}")
                except Exception:
                    pass
                self.corrections = {}
                self.hotwords = []

    def _save(self):
        # Atomic write: tmp file in same dir, then os.replace (atomic on POSIX).
        # Prevents JSON corruption if the process dies mid-write.
        payload = json.dumps({
            "corrections": self.corrections,
            "hotwords": self.hotwords,
        }, indent=2, ensure_ascii=False)
        tmp = self.path.with_suffix(self.path.suffix + ".tmp")
        tmp.write_text(payload)
        os.replace(tmp, self.path)

    def add_correction(self, wrong: str, right: str, auto_learned: bool = False) -> str:
        """Add a spelling correction. Returns notification message.

        auto_learned=True applies stricter validation to prevent garbage entries.
        """
        key = wrong.lower()

        if auto_learned:
            if len(key) < 3 or len(right) < 3:
                return f"Skipped (too short): \"{wrong}\" → \"{right}\""
            if key in self.PROTECTED_WORDS or right.lower() in self.PROTECTED_WORDS:
                return f"Skipped (common word): \"{wrong}\" → \"{right}\""
            if not key.isalpha() or not right.replace("'", "").isalpha():
                return f"Skipped (not alphabetic): \"{wrong}\" → \"{right}\""

        self.corrections[key] = right
        if right not in self.hotwords:
            self.hotwords.append(right)
        self._save()
        return f"Dictionary updated: \"{wrong}\" → \"{right}\""

    def add_hotword(self, word: str):
        """Add a word Whisper should recognize (proper noun, brand, etc.)."""
        if word not in self.hotwords:
            self.hotwords.append(word)
            self._save()

    def reset(self, keep_entries: dict[str, str] | None = None):
        """Delete dictionary and recreate with only known-good entries."""
        self.corrections = keep_entries or {}
        self.hotwords = list(keep_entries.values()) if keep_entries else []
        self._save()

    def apply(self, text: str) -> str:
        """Apply all corrections to transcribed text."""
        for wrong, right in self.corrections.items():
            pattern = re.compile(r'\b' + re.escape(wrong) + r'\b', re.IGNORECASE)
            text = pattern.sub(right, text)
        return text

    def get_hotwords_prompt(self) -> str:
        """Build a prompt hint string for Whisper initial_prompt."""
        if not self.hotwords:
            return ""
        return "Known names and terms: " + ", ".join(self.hotwords) + ". "
