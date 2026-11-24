# Security

AlwaysUp runs as you, with no extra privileges of its own. The security-relevant parts are:

- **The sudoers rule** (`/etc/sudoers.d/alwaysup`, only if you enable Passwordless mode). It allows
  your user to run exactly four fixed `pmset` commands as root without a password: turning
  `disablesleep` and battery `lowpowermode` on or off. It is validated with `visudo -c` before being
  installed, and contains no wildcards.
- **Process signals.** Saver Mode sends `SIGSTOP` / `SIGCONT` (and, for "quit when time's up",
  `SIGTERM`) to your own processes only.
- **The request folder** (`~/Library/Application Support/AlwaysUp/requests`). The `alwaysup` command
  drops small JSON files here for the app. Anything that can write to your home folder can ask the
  app to keep a process awake; it cannot make the app run commands.
- **Phone notifications.** If you set an address, the names of your kept items are POSTed to it.
  Nothing else leaves the Mac.
- **Docker.** The app talks to the local Docker socket to list, pause, unpause and stop containers.

## Reporting a vulnerability

Please report security problems privately through the repository's "Report a vulnerability" button
(GitHub Security Advisories) rather than a public issue. Include how to reproduce it and what an
attacker could gain.
