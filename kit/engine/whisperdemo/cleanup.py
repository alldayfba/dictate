#!/usr/bin/env python3
"""
WhisperShell — transcript cleanup.

VERBATIM PORT of `clean_transcript` / `FILLER_PATTERNS` / `_api_cleanup` from
the monolith (execution/whisper_flow.py, lines ~1612-1666). Only semantic
change: cleanup mode is now a function parameter instead of a module-level
env-var global, so callers can pick regex/api/none per-call without mutating
process state.
"""

from __future__ import annotations

import re

FILLER_PATTERNS = [
    re.compile(r'\b(um+|uh+m?|er+m?|ah+|eh+|hm+|hmm+)\b', re.IGNORECASE),
    re.compile(r'\b(you know,?\s*|I mean,?\s*|like,?\s+(?=you know|basically|literally))', re.IGNORECASE),
    re.compile(r'\s*\.\.\.\s*'),  # ellipsis from hesitation
]


def clean_transcript(text: str, mode: str = "regex") -> str:
    """Clean up transcription: remove filler words, fix punctuation, capitalize.

    mode: "regex" (default, always-on cleanup), "api" (regex + Claude Haiku
    polish), or "none" (no-op passthrough).
    """
    if mode == "none":
        return text

    # Regex cleanup (always runs for 'regex' and 'api' modes)
    for pattern in FILLER_PATTERNS:
        text = pattern.sub(' ', text)

    # Collapse multiple spaces
    text = re.sub(r'\s{2,}', ' ', text)
    # Fix orphaned punctuation (space before comma/period)
    text = re.sub(r'\s+([,.\?!;:])', r'\1', text)
    # Capitalize first letter of sentences
    text = re.sub(r'(^|[.!?]\s+)([a-z])', lambda m: m.group(1) + m.group(2).upper(), text)
    text = text.strip()

    # Optional Claude Haiku API polish
    if mode == "api" and text:
        text = _api_cleanup(text)

    return text


def _api_cleanup(text: str) -> str:
    """Use Claude Haiku to polish transcription. ~$0.001 per call."""
    try:
        import anthropic
        client = anthropic.Anthropic()
        response = client.messages.create(
            model="claude-haiku-4-5-20251001",
            max_tokens=1024,
            messages=[{
                "role": "user",
                "content": (
                    "Clean up this voice transcription. Remove filler words, fix grammar, "
                    "add proper punctuation and capitalization. Keep the meaning identical. "
                    "Return ONLY the cleaned text, nothing else.\n\n" + text
                ),
            }],
        )
        return response.content[0].text.strip()
    except Exception as e:
        print(f"[WhisperFlow] API cleanup failed: {e}, using regex-only")
        return text
