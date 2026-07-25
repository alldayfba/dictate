# Dictate — free AI dictation for your Mac

Hold a key, talk, and clean text appears wherever your cursor is — in any app.
Your voice never leaves your computer. Built for you, on your Mac, by Claude.

**What it does**
- Hold **Right Option** → speak → release → text pastes at your cursor
- Quick-tap to go hands-free, tap again to stop · **Esc** cancels
- Say *"send it Friday — no wait, Monday"* and it types "Send it Monday." —
  filler words and self-corrections are cleaned up automatically (AI Polish,
  powered by your own Claude account)
- 100% private: transcription runs on your Mac. No uploads, no accounts, no telemetry.

## Install (2 commands + talk to Claude)

You need: a Mac (macOS 13+), [Claude Code](https://claude.com/claude-code), and
Apple's command line tools (Claude will help you install them if missing).

```bash
git clone https://github.com/alldayfba/dictate.git ~/.claude/skills/dictate
claude "install dictate"
```

Claude builds the app from this source right on your machine, walks you through
the three macOS permission toggles, and tests it with you. First dictation
downloads the speech model (~874MB) — one time only.

## Problems?

Just tell Claude: `claude "dictate isn't working"` — the skill knows how to
diagnose and fix itself.

## Uninstall

Delete three things: `/Applications/Dictate.app`,
`~/Library/Application Support/WhisperDemo/`, and `~/.claude/skills/dictate/`.
That's everything it ever touches.

---
Made by [AllDayFBA](https://github.com/alldayfba) · Everything runs locally ·
AI Polish uses your own Claude login and sends text only, and you can switch it
off in the 🟥 menubar menu.
