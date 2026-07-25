#!/usr/bin/env python3
"""
WhisperDemo — state path resolution.

Own state dir (~/Library/Application Support/WhisperDemo/) so the demo never
writes into production's WhisperFlow state. The ONE deliberate share is the
models dir: it points at production's model cache so the 874MB whisper weights
are read-shared instead of re-downloaded (pywhispercpp only reads the file).
"""

from __future__ import annotations

import os
from pathlib import Path

APP_NAME = "WhisperDemo"


def state_dir() -> Path:
    """Root state directory: ~/Library/Application Support/WhisperDemo/"""
    d = Path.home() / "Library" / "Application Support" / APP_NAME
    d.mkdir(parents=True, exist_ok=True)
    return d


def dictionary_path() -> Path:
    """Path to the custom-dictionary JSON store (demo's own)."""
    return state_dir() / "dictionary.json"


def history_db_path() -> Path:
    """Path to the transcription-history SQLite DB (demo's own)."""
    return state_dir() / "history.db"


def config_path() -> Path:
    """Path to the engine config JSON (demo's own)."""
    return state_dir() / "config.json"


def models_dir() -> Path:
    """Whisper model weights — READ-SHARED with production so the demo reuses the
    existing ggml-large-v3-turbo-q8_0.bin instead of downloading 874MB again.
    Never delete/rename anything in here. Falls back to a demo-owned dir if the
    production cache doesn't exist (fresh machine)."""
    shared = Path.home() / "Library" / "Application Support" / "WhisperFlow" / "models"
    if shared.is_dir():
        return shared
    d = state_dir() / "models"
    d.mkdir(parents=True, exist_ok=True)
    return d


def log_path(name: str) -> Path:
    """Path to a named log file under the state dir, e.g. log_path('engine')."""
    return state_dir() / f"{name}.log"


def rotate_log(path: Path, max_bytes: int = 2_000_000) -> bool:
    """Rotate a log file if it exceeds max_bytes. Never raises."""
    try:
        if not path.exists():
            return False
        if path.stat().st_size <= max_bytes:
            return False
        rotated = path.with_suffix(path.suffix + ".1")
        os.replace(path, rotated)
        return True
    except OSError:
        return False
