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

Other useful targets:

```sh
make build         # debug build
make demo-check    # check that the demo sessions land in the expected groups (CI runs this)
make screenshots   # render the README screenshots from the demo data
make app           # build "Copilot Pulse.app" into ./build without installing
make package       # build the universal app for a release, check it and zip it into build/release
make install       # build the app, copy it to ~/Applications and launch it
make icon          # regenerate Resources/AppIcon.icns
```

[How it works](docs/how-it-works.md) explains where the data comes from and how updates are
pushed without polling.

## Project layout

```text
Sources/PulseCore/      the engine; UI-free, and fully tested
  CopilotPaths          where the app keeps its files
  AppDatabase           read-only SQLite queries (sessions, workspaces, unread markers, activity)
  EventLogReader        reads new lines from the end of events.jsonl
  EventLineParser       turns a JSON line into a LogEvent
  SessionLogState       tracks a session's state from its log events
  StatusResolver        combines database and log state into what the UI shows
  FileEventStream       FSEvents wrapper
  FileWriteWatcher      kqueue watcher for the SQLite WAL file
  SessionEngine         wires it all together and publishes snapshots
Sources/CopilotPulse/   the AppKit/SwiftUI app: menu bar, widget panel, settings, CLI
Tests/PulseCoreTests/   Swift Testing suites, including live FSEvents/kqueue tests on temp files
scripts/                app bundling, packaging and signing, the icon, and the demo data
```

## Debugging

The app binary doubles as a command-line tool:

```sh
.build/debug/CopilotPulse --dump            # table of every session and its status
.build/debug/CopilotPulse --json            # the same as JSON, with counts
.build/debug/CopilotPulse --watch           # print status changes live as they happen
.build/debug/CopilotPulse --render <dir>    # draw the panel and each widget size (light and dark) to PNGs
```

`make dump`, `make watch` and `make render` run these from a debug build. Set
`COPILOT_PULSE_COPILOT_DIR` to read a different Copilot data directory; `make demo` uses it to
point the app at `build/demo`.

Diagnostics go to the system log:

```sh
log show --last 10m --info --predicate 'subsystem == "com.asaf.CopilotPulse"' --style compact
```

## Building with only the Command Line Tools

- `make test` passes Swift Testing's macro plugin folder to the compiler explicitly. Without it,
  `swift test` sometimes fails with "plugin for module 'TestingMacros' not found".
- The `@State`, `@Entry` and `#Preview` SwiftUI macros aren't available without Xcode, so the
  views use a small `@LocalState` property wrapper instead of `@State`.

## Ground rules

- **Never change the Copilot app's data.** Open its files read-only, keep database reads short
  and never run SQL that writes (including `PRAGMA` settings and checkpoints). A read-only SQLite
  connection still takes brief shared locks and updates `data.db-shm`, as every reader does;
  that's expected.
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
- Update the README, or [How it works](docs/how-it-works.md), when behavior or settings change.
- For UI changes, include before and after screenshots from `make screenshots`.

## Releasing

Releases are built by GitHub Actions, not on a maintainer's Mac.

1. Set the new version as `CFBundleShortVersionString` in `Resources/Info.plist`, and increase
   `CFBundleVersion`.
2. Add a section for it at the top of `CHANGELOG.md`, such as `## 0.2.0 - 2026-11-30`. It becomes
   the release notes, so write it for users.
3. Push to `main` and wait for CI. Its macOS 26 job uploads the packaged app as the
   `Copilot-Pulse` artifact, and the next jobs run that app on macOS 15 on Apple silicon and Intel.
4. Tag the commit and push the tag:

   ```sh
   git tag v0.2.0
   git push origin v0.2.0
   ```

The tag starts the [release workflow](.github/workflows/release.yml). It checks that the tag
matches `Info.plist`, builds and tests the universal app on macOS 26, attests its build provenance
and publishes the release with `Copilot-Pulse.zip`, its SHA-256 and the changelog section. The
app is signed ad hoc and isn't notarized, which is why the README explains the Gatekeeper step.

## License

Copilot Pulse is licensed under the GNU General Public License, version 3 or later. By
contributing, you agree that your contributions are licensed under the same terms.
