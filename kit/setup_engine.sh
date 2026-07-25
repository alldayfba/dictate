#!/bin/bash
# Dictate — install the transcription engine: a private Python venv + the engine
# package under ~/Library/Application Support/WhisperDemo/. Compiles whisper.cpp
# with Metal via pywhispercpp (needs Xcode Command Line Tools; 2–5 min once).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="$HOME/Library/Application Support/WhisperDemo"
VENV="$STATE/engine-venv"
KIT="$STATE/kit"

command -v python3 >/dev/null || { echo "FATAL: python3 not found — install Xcode Command Line Tools: xcode-select --install"; exit 1; }
xcode-select -p >/dev/null 2>&1 || { echo "FATAL: Xcode Command Line Tools missing — run: xcode-select --install"; exit 1; }

mkdir -p "$STATE"
chmod 700 "$STATE"

if [ ! -x "$VENV/bin/python" ]; then
  echo "[engine] creating venv at $VENV"
  python3 -m venv "$VENV"
fi
echo "[engine] installing numpy + pywhispercpp (compiles whisper.cpp w/ Metal — takes a few minutes once)"
"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet numpy pywhispercpp

echo "[engine] installing engine package → $KIT/whisperdemo"
rm -rf "$KIT/whisperdemo"
mkdir -p "$KIT"
cp -R "$HERE/engine/whisperdemo" "$KIT/whisperdemo"

echo "[engine] import check"
cd "$KIT" && "$VENV/bin/python" -c "import whisperdemo.engine, whisperdemo.rewrite; print('engine OK')"
echo "[engine] DONE. First dictation will download the whisper model (~874MB) once."
