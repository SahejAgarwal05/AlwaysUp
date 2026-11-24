# Contributing

Thanks for wanting to help. AlwaysUp is a small project; bug reports, fixes and new agent
definitions are all welcome.

## Getting set up

You need macOS 13+ and Apple's Command Line Tools (`xcode-select --install`). There is no Xcode
project and there are no dependencies.

```bash
./build.sh                 # build build/AlwaysUp.app
Tests/run_unit_tests.sh    # fast, changes nothing on your Mac — run this before every pull request
Tests/run_tests.sh         # end-to-end on real hardware; needs passwordless mode, briefly mutes speakers
```

To try behaviour without closing the lid, use `alwaysup simulate` (see the README).

## Where things are

| File | What's in it |
|---|---|
| `Sources/Engine.swift` | All the rules: when to stay awake, timers, guards, Saver Mode |
| `Sources/System.swift` | Every call to the outside world, as one swappable struct (the tests replace it) |
| `Sources/Power.swift` | `pmset`, lid, battery, radios |
| `Sources/Processes.swift` | Process list and agent detection |
| `Sources/Docker.swift` | Docker socket client |
| `Sources/Events.swift` | System notifications that trigger a check |
| `Sources/CLI.swift` | The `alwaysup` command |
| `Sources/Views.swift`, `SimpleView.swift`, `Components.swift` | The window |
| `Tests/UnitTests.swift` | Rules tested against a fake Mac |

## Guidelines

- New behaviour in the engine should come with a unit test. Anything that touches hardware goes
  through `System`, so it can be faked.
- Anything the app changes on the Mac (sleep setting, paused processes, radios, mute) must be
  restored on quit and after a crash. If you add one, add it to the restore path too.
- Keep it dependency-free and buildable with plain `swiftc`.
- To add an agent, extend the list in `Sources/Processes.swift` and add a check to the
  "agent detection" section of the unit tests.

## Reporting bugs

Please include your macOS version, Mac model, and the output of
`/Applications/AlwaysUp.app/Contents/MacOS/AlwaysUp --diagnose`.

By contributing you agree that your contribution is licensed under the MIT License.
