# Disclaimer

AlwaysUp is free, open-source software provided **"as is", without warranty of any kind**, as set
out in the [MIT License](LICENSE). You use it entirely at your own risk.

By using it you accept that:

- **Heat and hardware.** AlwaysUp overrides macOS's normal behaviour of sleeping when the lid is
  closed. A laptop that stays awake in a bag, sleeve or other enclosed space can get very hot, which
  can damage the Mac, its battery or things around it. Do not leave it running where it cannot cool
  down. The battery and overheating guards reduce this risk but do not remove it, and they can fail.
- **Battery.** Keeping the Mac awake drains the battery and can add to battery wear.
- **Your work.** Saver Mode pauses and can quit other apps, and can switch off Wi‑Fi and Bluetooth.
  Paused or quit apps may lose unsaved work, drop connections or miss deadlines. Time limits can
  pause, stop or quit the processes and containers you attach them to.
- **System settings.** AlwaysUp changes the system sleep setting (`pmset disablesleep`) and, if you
  enable Passwordless mode, adds a rule to `/etc/sudoers.d`. If the app and its watchdog both fail,
  sleep can stay disabled until you run `sudo pmset -a disablesleep 0`.
- **Future macOS versions.** It relies on some undocumented macOS behaviour that Apple may change or
  remove at any time. It may stop working, or work differently, after a system update.
- **Agents and costs.** Keeping AI agents running means they keep using whatever they use: API
  credits, subscriptions, network data. AlwaysUp does not watch or limit that.
- **Notifications.** If you set a phone notification address, the names of your kept items are sent
  to that third-party service.

The authors and contributors are not liable for any damage, data loss, cost or other harm arising
from its use. It is not suitable for safety-critical use.

AlwaysUp is an independent project. It is not affiliated with, endorsed by or supported by Apple,
Anthropic, OpenAI, Google, Docker or any other company whose products it detects or works with. All
product names and trademarks belong to their owners.

The downloadable DMG is not notarized by Apple. Only download it from this repository, and check
the SHA-256 on the release page if you want to be sure it hasn't been altered.
