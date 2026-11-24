# Changelog

## 1.1

- "Always keep every <agent>" rule: keeps every session of an agent, including ones started later.
- `alwaysup done` / `busy` are tracked per session, so one finished session doesn't release the Mac
  while another is still working.
- An agent started by another agent only reports `done` for itself, not for the one that started it.
- A notification when a single session under a rule finishes ("Claude Code finished · 2 still running").
- "Check for Updates…" in the menu (opens the releases page).
- `./build.sh --uninstall` keeps going, with instructions, when it can't get admin rights.

## 1.0

First public release.

- Keep the Mac awake with the lid closed, for a set time, until a battery level, or until turned off.
- Detect AI agents (Claude Code, Codex, Gemini CLI, Aider, Cursor and others) and keep the Mac awake while they run.
- Kept items by process, app or Docker container, each with its own time limit and action.
- Saver Mode: pause other apps, display off, Bluetooth / Wi‑Fi off, Low Power Mode, mute.
- Battery guard, overheating guard and optional idle detection.
- Crash watchdog that re-enables sleep and resumes paused apps.
- Phone notifications through an ntfy-style address, and a "While you were away" summary.
- `alwaysup` command: `run`, `done`, `busy`, `simulate`.
