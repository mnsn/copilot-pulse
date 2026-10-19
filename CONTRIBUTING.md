# Contributing to Copilot Pulse

Thanks for your interest! Bug reports, ideas and pull requests are all welcome.

## Getting started

You need macOS 15 or later and Swift 6. Xcode works, and so do just the Command Line Tools.

```sh
git clone https://github.com/mnsn/copilot-pulse.git
cd copilot-pulse
make test    # run the tests
make demo    # run the app with made-up sessions (Ctrl-C to quit)
make run     # run the app with your own ~/.copilot
```

`make demo` creates a fake Copilot data directory in `build/demo` with a session in every
state. Use it to work on the UI and to take screenshots without showing your own sessions.

## Ground rules

- **Read-only.** Copilot Pulse must never write to, lock or otherwise change the Copilot app's
  files. Open everything read-only.
- **No network.** The app makes no network connections and collects no data. Keep it that way.
- **Logic goes in `PulseCore`.** Keep it free of UI code and cover changes with tests in
  `Tests/PulseCoreTests`. The app target only displays what the engine publishes.
- **Use made-up data.** Session names, prompts, logs and paths from your own Copilot sessions
  are private. Don't put them in tests, screenshots, issues or pull requests.
- **The Copilot app's files are undocumented.** When you rely on a new field or event, handle
  its absence and add a test with a small made-up sample.

## Pull requests

- Keep each pull request focused, and describe the change users will see.
- Run `make test` first. CI also runs it on macOS 15 and macOS 26.
- Update the README when behavior or settings change.
- For UI changes, include before and after screenshots from `make screenshots`.

## License

Copilot Pulse is licensed under the GNU General Public License, version 3 or later. By
contributing, you agree that your contributions are licensed under the same terms.
