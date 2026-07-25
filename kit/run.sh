#!/bin/bash
# Dictate — install Dictate.app to /Applications, write config, launch.
# Usage: bash run.sh [claude_config_dir]
#   claude_config_dir: where the student's Claude Code login lives (for the
#   optional AI Polish). Defaults to $CLAUDE_CONFIG_DIR or ~/.claude.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_APP="$HERE/build/Dictate.app"
DEST_APP="/Applications/Dictate.app"
STATE="$HOME/Library/Application Support/WhisperDemo"
VENV="$STATE/engine-venv"
KIT="$STATE/kit"
CLAUDE_DIR="${1:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}"
CLAUDE_BIN="$(command -v claude || echo /opt/homebrew/bin/claude)"

[ -d "$SRC_APP" ] || { echo "FATAL: build first (bash build.sh)"; exit 1; }
[ -x "$VENV/bin/python" ] || { echo "FATAL: engine missing (bash setup_engine.sh)"; exit 1; }

echo "[run] installing → $DEST_APP"
rm -rf "$DEST_APP"
cp -R "$SRC_APP" "$DEST_APP"
xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true

CFG="$STATE/config.json"
if [ ! -f "$CFG" ]; then
  echo "[run] writing config.json"
  cat > "$CFG" <<JSON
{
  "engine": "pywhispercpp",
  "cleanup_mode": "regex",
  "hotkey_keycode": 61,
  "tap_latch_seconds": 0.35,
  "preroll_seconds": 0.75,
  "stream_preview": false,
  "stream_interval_ms": 550,
  "python_path": "$VENV/bin/python",
  "engine_cwd": "$KIT",
  "ai": {
    "mode": "on",
    "transport": "cli",
    "cli_path": "$CLAUDE_BIN",
    "claude_config_dir": "$CLAUDE_DIR",
    "model": "haiku",
    "timeout_s": 10.0,
    "min_words": 5,
    "app_tone_map": {}
  }
}
JSON
fi
chmod 700 "$STATE"

echo "[run] launching"
open "$DEST_APP"

cat <<EOF

[run] Dictate is up (🟥 in the menubar).
[run] HOLD Right Option to talk · quick-tap to latch · Esc cancels.
[run] One-time: System Settings → Privacy & Security → enable Dictate under
      Microphone, Accessibility, AND Input Monitoring — then relaunch the app.
[run] First dictation downloads the speech model (~874MB) — give it a few minutes.
[run] Logs: tail -f "$STATE/shell.log" "$STATE/engine.log"
EOF
