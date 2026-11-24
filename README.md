# AlwaysUp

A macOS menu bar app that keeps your Mac — and your AI agents — running with the lid closed.

> **Use at your own risk.** AlwaysUp stops your Mac sleeping with the lid closed, which can make it
> hot in a bag, drain the battery and pause or quit other apps. It comes with no warranty and isn't
> affiliated with Apple or any AI vendor. Read the [disclaimer](DISCLAIMER.md) before using it.

## Install

You need a Mac on macOS 13 (Ventura) or newer and Apple's Command Line Tools
(`xcode-select --install`). Xcode itself is not needed.

```bash
git clone https://github.com/SahejAgarwal05/AlwaysUp.git && cd AlwaysUp
./build.sh --install
```

That compiles the app, copies it to `/Applications` (or `~/Applications` if you aren't an admin),
launches it and adds an `alwaysup` command when `/opt/homebrew/bin` or `/usr/local/bin` is writable.
Look for the AlwaysUp icon in the menu bar. Because you built it yourself, macOS doesn't block it.

Developed and tested on an Apple Silicon Mac with Swift 6.2. Intel Macs should work but are untested.

### Or download the app

**[Download AlwaysUp-1.1.dmg](https://github.com/SahejAgarwal05/AlwaysUp/raw/main/dist/AlwaysUp-1.1.dmg)**
(also on the [releases page](https://github.com/SahejAgarwal05/AlwaysUp/releases)). It runs on
Apple Silicon and Intel Macs with macOS 13 or newer: open it and drag AlwaysUp to Applications. That copy isn't notarized by Apple, so the first time you open it macOS
will refuse; go to **System Settings → Privacy & Security** and click **Open Anyway**. Building from
source avoids this.

## Uninstall

```bash
./build.sh --uninstall
```

Quits the app, removes it, the `alwaysup` command, the sudoers rule below and its settings, and
makes sure sleep is switched back on.

## What it changes on your Mac

- **Sleep setting.** While it's keeping the Mac awake it runs `sudo pmset -a disablesleep 1`, and
  sets it back to `0` when it stops, when you quit, and (through a small watchdog process) if the
  app crashes or is force-quit. If you ever need to undo it by hand: `sudo pmset -a disablesleep 0`.
- **A sudoers rule, only if you turn on "Passwordless mode".** The app asks for your password once
  and writes `/etc/sudoers.d/alwaysup` containing exactly this one line (with your user name):

  ```
  you ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -b lowpowermode 0, /usr/bin/pmset -b lowpowermode 1
  ```

  It lets your user run those four commands without a password and nothing else. Without it, macOS
  asks for your password each time the app switches sleep on or off, which you can't see with the
  lid closed. Turn the switch off in the app, or run `sudo rm /etc/sudoers.d/alwaysup`, to remove it.
- **Files.** Settings in the `local.alwaysup` preferences, and a little state in
  `~/Library/Application Support/AlwaysUp`.
- **Network.** Nothing is sent anywhere unless you set a phone notification address.

## Safety

A laptop that stays awake with the lid closed gets warm, especially in a bag. The battery guard and
overheating guard (both on by default) let the Mac sleep when the battery runs low or it gets hot,
but this is free software with no warranty: don't leave it running somewhere it can't cool down.

## Building and testing

```bash
./build.sh                # builds build/AlwaysUp.app without installing
build/AlwaysUp.app/Contents/MacOS/AlwaysUp --diagnose   # show what it detects; changes nothing
Tests/run_unit_tests.sh   # fast tests of the rules against a fake Mac; no admin rights, changes nothing
Tests/run_tests.sh        # end-to-end self-test on the real hardware; needs passwordless mode
```

The unit tests swap everything the engine touches (pmset, signals, radios, audio, Docker, the clock)
for a fake, so they run anywhere in a second.

The end-to-end self-test drives the real engine with a simulated lid/monitor/battery, a dummy app to
pause, and a fake Docker server. It never touches Wi‑Fi, Bluetooth or the screen, only pauses its own
dummy app, briefly mutes the speakers, and restores everything when done.

`./build.sh --dmg` builds a universal app and packs `build/AlwaysUp-<version>.dmg` (copy it to `dist/` for a release)
(the version number is at the top of `build.sh`). With a Developer ID certificate and
`ALWAYSUP_NOTARY_PROFILE` set to a stored `notarytool` profile it also notarizes the image; that
path is untested, since the project has no certificate yet.

**Signing.** `build.sh` signs with the first Developer ID / Apple Development certificate in your
keychain (or the one named in `ALWAYSUP_SIGN_ID`), and falls back to an ad-hoc signature, which is
fine for a copy you build yourself. A real certificate keeps the app's identity the same across
rebuilds, so macOS doesn't forget its notification and open-at-login permissions.

## Features

- **Keep awake with lid closed** — custom duration (hours + minutes), presets, or unlimited.
- **Agent detection** — Claude Code, Codex CLI, Gemini CLI, Aider, Cursor Agent, OpenCode, Goose, Amp,
  Copilot CLI, Qwen Code, Crush, Cline, Open Interpreter, Ollama, plus the Claude / ChatGPT / Codex /
  Cursor / Windsurf apps. One click to mark them "kept running".
- **Always keep every Claude Code** (or any other agent) — one saved switch per kind of agent. Every
  session of it is kept, including ones you start later or that an agent starts in parallel, with no
  need to pick process IDs. Single sessions can still be switched off by hand, and you're told when
  each one finishes. Sub-agents that run
  inside a session are part of that session's process, so they're always covered.
- **Kept items** — add by detected agent, PID, process name, running app, app from disk, or by browsing
  all processes. Each has its own time limit (or unlimited) and its own action when time's up:
  release (let Mac sleep), pause the process, or quit it. The Mac stays awake while any kept item runs.
- **Saver Mode** (when lid closed, or whenever awake):
  - pause every app you didn't mark (apps your agents run inside — Terminal, VS Code, tmux — are protected)
  - turn display off · Bluetooth off · Wi‑Fi off (warns: online agents need it) · Low Power Mode on battery
  - everything is restored when it ends, on quit, or on next launch after a crash
  - lid closed + external monitor counts as "in use" by default
- **Docker containers** — finds running containers (Docker Desktop, OrbStack, Colima, Rancher, Podman)
  over the Docker socket. Keep one running like any other item; its timer can pause or stop the
  container, it's still tracked when `docker compose up` recreates it, and the Docker runtime is
  protected from Saver Mode while a kept container is up.
- **Battery guard** — lets the Mac sleep when on battery below a threshold.
- **Overheating guard** — if the Mac gets hot while the lid is closed (say, in a bag), it's allowed to sleep.
- **Idle detection** (off by default) — a kept item that has used almost no CPU for the time you pick
  (an agent sitting at its prompt) stops holding the Mac awake, and holds it again as soon as it's busy.
  Containers are never treated as idle.
- **Time limits count per run** — an app or process-name item's limit starts when it starts running,
  so "Claude, 2 hours" works every time you launch it, not just the first.
- **Phone notifications** — paste an [ntfy](https://ntfy.sh) topic address and "agent finished",
  "time's up", "battery low" and friends also reach your phone while the lid is closed. The names of
  your kept items are sent to that address; nothing is sent unless you set one.
- **While you were away** — open the lid and see how long it stayed awake, what the battery did and what finished.
- **Crash-safe** — a tiny watchdog process outlives a crash or `kill -9`: it resumes anything left
  paused and re-enables sleep, so a crash can never leave the Mac awake in your bag.
- **Custom agents** — list extra program names to show as agents.
- **Passwordless mode** — installs `/etc/sudoers.d/alwaysup` allowing only
  `pmset -a disablesleep 0|1` and `pmset -b lowpowermode 0|1` for your user. Recommended, since
  AlwaysUp switches automatically (often with the lid closed, where a password prompt can't be seen).

## Command line

`./build.sh --install` links the app's binary as `alwaysup` (in `/opt/homebrew/bin` or `/usr/local/bin`,
when writable). Otherwise use `/Applications/AlwaysUp.app/Contents/MacOS/AlwaysUp`.

```bash
alwaysup run claude                       # keep the Mac awake (lid closed too) while this runs
alwaysup run --for 2h --then quit npm test   # …for at most 2 hours, then quit it (or: release, pause)
alwaysup done                             # "the agent I'm running inside is waiting for you"
alwaysup busy                             # "…and now it's working again"
```

`run` starts the app if needed and then *becomes* your command (same PID), so there's no wrapper in
the way. `done` / `busy` are meant for agent hooks — e.g. in Claude Code's `~/.claude/settings.json`:

```json
{ "hooks": {
    "Stop":             [{ "hooks": [{ "type": "command", "command": "alwaysup done" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "alwaysup busy" }] }]
} }
```

With that, the Mac is released the moment Claude finishes its turn (and you get a "waiting for you"
notification if the lid is closed), without waiting for the idle timer.

## Trying it without closing the lid

`alwaysup simulate` makes the running app believe the lid, monitor, battery or temperature is
different, so you can watch what it would do while sitting at your desk:

```bash
alwaysup simulate lid=closed              # as if you closed the lid and walked away
alwaysup simulate lid=closed battery=15   # …on battery at 15% (15+ means charging)
alwaysup simulate thermal=hot             # as if the Mac were overheating
alwaysup simulate off                     # back to the real readings
```

The window shows "Simulating: …" while it's on, and quitting the app ends it. Everything else is
real: with the lid "closed", Saver Mode really pauses apps and turns off whatever you've set it to.
The one thing it won't do is put the Mac to sleep, since that checks the real lid.

## How it works

- Lid, battery, app launch/quit, wake and thermal changes arrive as system notifications, so the
  regular check runs only every 10–30s (2s while the window is open) and off the main thread.
- When it stops keeping the Mac awake while the lid is already closed, it runs `pmset sleepnow`,
  since macOS otherwise waits for its idle timer.
- Saver Mode also pauses an app's XPC helpers (e.g. a browser's web content processes), which are
  started by launchd rather than by the app. App extensions are left alone.

- `pmset -a disablesleep 1` blocks lid-close sleep (the only reliable way; `caffeinate` alone can't).
- `caffeinate -ims` blocks idle sleep.
- Pausing uses `SIGSTOP` / `SIGCONT` on the app and its child processes.
- Grouping an app's helpers uses an undocumented macOS call; if a future macOS drops it, helpers
  simply aren't paused.

## Contributing

See the [disclaimer](DISCLAIMER.md), [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md) and the [changelog](CHANGELOG.md).

## License

MIT. See [LICENSE](LICENSE). AlwaysUp has no third-party dependencies. The names of the agents and
apps it detects belong to their owners; AlwaysUp isn't affiliated with any of them.
