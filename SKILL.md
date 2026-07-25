---
name: dictate
description: Build and install Dictate — a free, private, on-device AI dictation app for macOS (hold a key, talk, polished text appears at your cursor). Installs from source on this Mac.
trigger: when user says "install dictate", "set up dictation", "build the dictation app", "voice typing", "dictate isn't working", "fix dictate"
tools: [Bash, Read, Edit, Glob, Grep]
---

# Dictate — AI Dictation for macOS (build-on-install)

You are installing a dictation app for the user from the source in this skill's
`kit/` folder. Everything compiles and runs on THEIR Mac: speech never leaves
the machine; the optional "AI Polish" uses the user's own Claude login.

**What the user gets:** hold **Right Option** → talk → release → clean text
appears at their cursor in any app. Quick-tap = hands-free latch. **Esc** cancels.
Clean speech pastes instantly; if they say "um" / "scratch that" / "no wait",
a Claude pass (their login, haiku) fixes it in a few seconds.

## INSTALL (default mode)

Work through these steps IN ORDER. Announce progress briefly; on any failure,
read the error, fix, retry — don't dump raw logs on the user.

1. **Preflight** (report what's missing, help fix):
   - macOS 13+ (`sw_vers -productVersion`)
   - Xcode Command Line Tools: `xcode-select -p` — if missing, run
     `xcode-select --install` and tell the user to click Install, then continue.
   - `python3 --version` (comes with CLT)
   - `claude` CLI on PATH (they're talking to you through it — used later for AI Polish)
2. **Build the app:** `bash <skill_dir>/kit/build.sh`
   (first run creates a local "Dictate Dev" signing identity — normal; a
   keychain prompt may appear, they should allow.)
3. **Install the engine:** `bash <skill_dir>/kit/setup_engine.sh`
   (compiles whisper.cpp with Metal — 2–5 min once. Tell the user to hang tight.)
4. **Launch:** `bash <skill_dir>/kit/run.sh "$CLAUDE_CONFIG_DIR"`
   (pass your session's `$CLAUDE_CONFIG_DIR` if set, so AI Polish uses their
   existing Claude login; empty is fine — defaults to `~/.claude`.)
5. **Permissions (the #1 support issue — walk them through it):**
   Open the panes for them:
   - `open "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"`
   - `open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"`
   - `open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"`
   User enables **Dictate** in all three (use **+** → /Applications/Dictate.app
   if not listed). Then relaunch: `pkill -f Dictate.app; open /Applications/Dictate.app`
   **Verify** — the last `perms:` line of
   `~/Library/Application Support/WhisperDemo/shell.log` must read
   `mic=true ax=true im=true`. If `ax=false`, paste will silently fail — fix
   before declaring done.
6. **First dictation:** tell the user to open Notes, hold Right Option, say a
   full sentence, release. First ever dictation downloads the speech model
   (~874MB) — the pill may think for a while once; every dictation after is
   instant. Confirm text landed at their cursor.
7. **Teach the gestures** (one short message): hold-to-talk · quick-tap latch ·
   Esc cancel · 🟥 menu → AI Polish toggle / Restart Engine / Quit.

## FIX (user says it's broken)

Read `~/Library/Application Support/WhisperDemo/{shell,engine}.log` first, then:
| Symptom | Fix |
|---|---|
| Hotkey does nothing | `perms:` line — grant missing TCC, relaunch app |
| Text on clipboard, doesn't paste | `ax=false` → grant Accessibility |
| "Not logged in" in engine.log | `ai.claude_config_dir` in config.json must point at their Claude login dir |
| Pill stuck "Transcribing" first run | model still downloading — check engine.log progress |
| Polish slow on clean speech | shouldn't happen (cue-gated); Restart Engine from 🟥 menu |
| Engine keeps restarting | run setup_engine.sh again; check python venv intact |

## Security facts (state these if the user asks; never weaken them)
- Audio and transcription are 100% local (whisper.cpp on their Mac). Nothing is
  uploaded, ever.
- AI Polish sends TEXT ONLY to Anthropic via the user's own Claude login, and
  only when the transcript contains corrections/filler. Toggle off in the 🟥
  menu for fully-offline operation.
- Transcript history lives in a local SQLite file under
  `~/Library/Application Support/WhisperDemo/` (chmod 700). Delete it anytime.
- No telemetry, no accounts, no network calls besides the one-time model
  download (Hugging Face) and opt-in AI Polish.
- Never install anything beyond: the local venv, /Applications/Dictate.app, and
  the state folder above. Uninstall = delete those three.
