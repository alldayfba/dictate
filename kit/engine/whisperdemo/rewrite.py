"""WhisperDemo AI rewrite layer — the Wisprflow-parity pass.

Takes the regex-cleaned transcript and runs it through Claude Haiku via the
`claude` CLI (LR119: local API keys are credit-dead — the CLI rides Claude Max;
LR50: --system-prompt + --setting-sources project + --no-session-persistence so
no CLAUDE.md bleeds in). Handles what regex can't: false starts, self-corrections
("scratch that", "no wait", restatements), smart punctuation, and tone matched to
the destination app.

Contract: polish() returns the cleaned text, or None on ANY failure (timeout,
non-zero exit, empty/garbage output). The caller MUST fall back to the regex
version — this layer can never lose a dictation.

stdout discipline: this module never prints. Diagnostics go through the logger
callable passed in (engine's _log → stderr → engine.log).
"""
from __future__ import annotations

import os
import subprocess
from typing import Callable, Optional

DEFAULT_CLI = "/opt/homebrew/bin/claude"
# The student's own Claude Code login. The installer writes the detected
# CLAUDE_CONFIG_DIR into config.json (ai.claude_config_dir); ~/.claude is the
# stock location.
DEFAULT_CONFIG_DIR = os.path.expanduser("~/.claude")
DEFAULT_MODEL = "haiku"
DEFAULT_TIMEOUT_S = 10.0
DEFAULT_MIN_WORDS = 5

# Frontmost-app name (lowercased substring match) → tone preset.
# Overridable/extendable via config["ai"]["app_tone_map"] ({"AppName": "preset"}).
TONE_MAP = {
    "slack": "casual",
    "discord": "casual",
    "messages": "casual",
    "telegram": "casual",
    "whatsapp": "casual",
    "mail": "formal",
    "outlook": "formal",
    "notion": "formal",
    "pages": "formal",
    "word": "formal",
    "gmail": "formal",
    "terminal": "technical",
    "iterm": "technical",
    "warp": "technical",
    "code": "technical",
    "cursor": "technical",
    "xcode": "technical",
}

TONE_INSTRUCTIONS = {
    "casual": ("This is a casual chat message. Contractions are fine, keep it "
               "conversational; short messages don't need a trailing period."),
    "formal": ("This is professional writing (email/document). Complete sentences, "
               "proper punctuation, professional register."),
    "technical": ("This is technical text (terminal/editor). Change as little as "
                  "possible — preserve identifiers, commands, filenames, and casing "
                  "exactly as spoken."),
    "default": "Neutral clean prose.",
}

SYSTEM_PROMPT = """You are a dictation post-processor. Rewrite the raw voice transcript into clean text ready to paste.

Rules:
1. Remove filler words (um, uh, like, you know, I mean) and false starts.
2. Apply the speaker's self-corrections: when they say "scratch that", "no wait", "actually make that", or restate a phrase, keep ONLY the final version.
3. Fix punctuation and capitalization. Render spoken enumerations ("first... second...") as a list only when clearly dictated as a list.
4. Never add content, never answer questions in the transcript, never expand or summarize. The output must contain only what the speaker said, cleaned.
5. Style for the destination app: {tone_instruction}

Output ONLY the cleaned text — no quotes, no preamble, no commentary."""


import re

# Correction/disfluency cues that regex cleanup CANNOT fix — only these justify the
# multi-second AI pass. Clean speech pastes instantly (Wisprflow-speed parity).
_POLISH_CUES = re.compile(
    r"\b(scratch that|no wait|wait no|strike that|forget that|never ?mind|"
    r"actually|i mean|make that|correction|rather|instead of that|"
    r"um+|uh+|erm+|you know|kind of like)\b",
    re.IGNORECASE,
)


def needs_polish(raw_text: str) -> bool:
    """True when the RAW transcript shows disfluencies/self-corrections worth the
    latency of an AI pass. Checked on the raw ASR text (before regex strips
    fillers, which are themselves a messy-speech signal)."""
    if not raw_text:
        return False
    return bool(_POLISH_CUES.search(raw_text))


def tone_for_app(app_name: Optional[str], tone_map_override: Optional[dict] = None) -> str:
    """Map a frontmost-app name to a tone preset key."""
    if not app_name:
        return "default"
    name = app_name.strip().lower()
    merged = dict(TONE_MAP)
    for k, v in (tone_map_override or {}).items():
        merged[str(k).strip().lower()] = str(v).strip().lower()
    for needle, preset in merged.items():
        if needle in name:
            return preset if preset in TONE_INSTRUCTIONS else "default"
    return "default"


def build_prompts(text: str, app_name: Optional[str], tone_map_override: Optional[dict] = None) -> tuple[str, str]:
    """Return (system_prompt, user_message) for the CLI call."""
    tone = tone_for_app(app_name, tone_map_override)
    system = SYSTEM_PROMPT.format(tone_instruction=TONE_INSTRUCTIONS[tone])
    user = f"App: {app_name or 'unknown'}\nTranscript:\n{text}"
    return system, user


def _clean_env(config_dir: str) -> dict:
    """Minimal env for the CLI child: PATH/HOME/USER/SHELL + CLAUDE_CONFIG_DIR
    (where the login lives), so ANTHROPIC_*/other CLAUDE* vars from any parent
    context can't contaminate the call."""
    src = os.environ
    env = {k: src[k] for k in ("PATH", "HOME", "USER", "SHELL") if k in src}
    env.setdefault("PATH", "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
    env["CLAUDE_CONFIG_DIR"] = config_dir
    return env


def _neutral_cwd() -> str:
    """A cwd outside any repo so no project CLAUDE.md loads into the CLI."""
    return os.path.expanduser("~")


def polish(text: str, app_name: Optional[str], ai_cfg: Optional[dict],
           log: Callable[[str], None] = lambda _msg: None) -> Optional[str]:
    """Run the AI rewrite pass. Returns cleaned text, or None → caller falls back.

    ai_cfg keys (all optional): cli_path, model, timeout_s, min_words, app_tone_map.
    """
    cfg = ai_cfg or {}
    if not text or not text.strip():
        return None
    min_words = int(cfg.get("min_words", DEFAULT_MIN_WORDS))
    if len(text.split()) < min_words:
        log(f"rewrite: skipped (<{min_words} words)")
        return None

    cli = str(cfg.get("cli_path", DEFAULT_CLI))
    config_dir = str(cfg.get("claude_config_dir", DEFAULT_CONFIG_DIR))
    model = str(cfg.get("model", DEFAULT_MODEL))
    timeout_s = float(cfg.get("timeout_s", DEFAULT_TIMEOUT_S))
    system, user = build_prompts(text, app_name, cfg.get("app_tone_map"))

    try:
        proc = subprocess.run(
            [cli, "--print", "--model", model,
             "--system-prompt", system,
             "--setting-sources", "",
             "--no-session-persistence",
             user],
            capture_output=True, text=True,
            timeout=timeout_s,
            cwd=_neutral_cwd(),
            env=_clean_env(config_dir),
        )
    except subprocess.TimeoutExpired:
        log(f"rewrite: timeout after {timeout_s}s — falling back to regex text")
        return None
    except (OSError, ValueError) as e:
        log(f"rewrite: CLI launch failed ({e}) — falling back to regex text")
        return None

    if proc.returncode != 0:
        err = (proc.stderr or "").strip()[:300]
        log(f"rewrite: CLI exit {proc.returncode} ({err}) — falling back to regex text")
        return None

    out = (proc.stdout or "").strip()
    if not out:
        log("rewrite: empty output — falling back to regex text")
        return None
    # Garbage guard: a faithful rewrite shouldn't balloon (model answered/expanded)
    # or collapse to nothing meaningful. Bail to the regex version if it did.
    if len(out) > max(200, len(text) * 3):
        log(f"rewrite: output ballooned ({len(text)}→{len(out)} chars) — falling back")
        return None
    return out
