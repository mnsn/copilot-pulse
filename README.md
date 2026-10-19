# Copilot Pulse

[![CI](https://github.com/mnsn/copilot-pulse/actions/workflows/ci.yml/badge.svg)](https://github.com/mnsn/copilot-pulse/actions/workflows/ci.yml)
[![License: GPL v3](https://img.shields.io/badge/license-GPLv3-blue.svg)](LICENSE)

A small macOS menu-bar app, with an optional desktop widget, that shows at a glance what every
GitHub Copilot app session is doing: which ones are **running**, which **need you** (a question,
a plan to approve or a permission prompt), and which have **finished** or **stopped**.

It updates within a fraction of a second of a state change and doesn't depend on polling. It
reads the Copilot app's local files read-only, so there are no hooks to install and nothing to
configure.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/menu-dark.png">
    <img src="docs/images/menu-light.png" width="380" align="top" alt="The menu-bar panel, listing sessions in the groups Needs You, Running, Finished and Stopped">
  </picture>
  &nbsp;
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/widget-large-dark.png">
    <img src="docs/images/widget-large-light.png" width="352" align="top" alt="The large desktop widget, listing the same sessions with an icon for each state">
  </picture>
</p>

> [!NOTE]
> Copilot Pulse is an independent project. It isn't affiliated with or endorsed by GitHub.
> The screenshots show made-up sessions from `make demo`.

## Features

- **Menu bar**: the Copilot Pulse icon, followed by a symbol and count for each non-empty group:
  orange ✋ needs you, blue ⚡ running, green ✓ done, red ⚠ stopped. Click it to see every
  session by group.
- **Desktop widget**: a widget-style panel in three sizes, on the desktop behind your windows or
  floating above them. Drag it by its header, and right-click it for settings.
- **One click to a session**: click any session to open it in the Copilot app.
- **Instant**: driven by file-system events, so there's no refresh delay.
- **Private**: no network connections and no data collection.

## What the states mean

| Group | Status | When |
|---|---|---|
| **Needs you** | Waiting for your answer | The agent asked a question (choices are shown) |
| | Plan ready for review | The agent finished a plan and waits for approval |
| | Needs permission | A tool call is waiting for your permission |
| **Running** | Working | A turn is in progress (the current step is shown) |
| | Starting… | The app started a turn and the agent hasn't logged anything yet |
| **Done** | Finished | The turn ended normally; shows the agent's summary if there is one |
| **Stopped** | Interrupted | You cancelled the turn, or it was cut short (for example, the app quit mid-turn) |
| | Error | The session failed (the error is shown) |
| | Stopped responding | The log says "mid-turn", the app no longer marks it running, and it has been silent for 90 s |
| **Idle** | Idle | Everything else |

**Done** and **Stopped** sessions stay highlighted until you've seen them: you open the session
(from Copilot Pulse or in the Copilot app), click **Clear** on its group, or the
**Keep Finished Sessions For** time passes (1 hour by default). Then they move to Idle.

## Install

Requirements: macOS 15 or later, and Swift 6 from Xcode or the Command Line Tools
(`xcode-select --install`).

```sh
git clone https://github.com/mnsn/copilot-pulse.git
cd copilot-pulse
make install     # builds "Copilot Pulse.app", copies it to ~/Applications and launches it
```

Then turn on **Launch at Login** in its settings. If macOS asks you to allow it, use
**Allow in Login Items Settings…**. To remove the app, run `make uninstall`.

There's no prebuilt download: the app isn't notarized, so macOS would block a downloaded copy,
while one you build yourself opens normally.

## Settings

Open the gear menu in the menu-bar panel, or right-click the widget.

| Setting | Options |
|---|---|
| Show Desktop Widget | on/off |
| Widget Position | **On Desktop (Behind Windows)** like a real widget, or **Floating (Above Windows)** |
| Widget Size | Compact (2 rows), Medium (4), Large (8) |
| Keep Finished Sessions For | 15 minutes, 1 hour, 4 hours, 1 day |
| Launch at Login | on/off |

## Privacy

Copilot Pulse makes no network connections and collects no data. It reads the Copilot app's
files under `~/.copilot` read-only and never changes any of the app's data. All it stores is its
own settings and which sessions you've cleared, in its preferences on your Mac.

## FAQ

### Why not a real macOS widget?

macOS limits how often WidgetKit widgets refresh: a frequently viewed widget typically updates
every 15 to 60 minutes ([Apple's documentation](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)).
Reloads requested by a background app and push updates are budgeted too, and widget hosts such
as Pushcut or Scriptable are WidgetKit widgets with the same limit. So Copilot Pulse draws its
own widget-style panel, which it can redraw instantly. The trade-offs: it isn't in the widget
gallery, and the app has to be running.

### How does it update without polling?

The Copilot app and its agents already write every state change to disk: the app to its SQLite
database, and each agent to a log file. Copilot Pulse watches those files with FSEvents and
kqueue, and rereads only what changed. [How it works](docs/how-it-works.md) has the details.

### Will a Copilot app update break it?

It could. Copilot Pulse relies on the Copilot app's undocumented local files, which can change.
If the database layout changes, it falls back to a simpler view, and if it can't read the
database at all, it says so in the panel. Please
[open an issue](https://github.com/mnsn/copilot-pulse/issues) if that happens.

### Why do some sessions show less detail?

Questions, plans, permission prompts and the current step come from the agent's log on this Mac.
A session without a local log only shows Running, Interrupted or Idle, based on the Copilot app's
own flags.

### How do I troubleshoot it?

The app binary has debugging options, and logs diagnostics to the system log:

```sh
APP="$HOME/Applications/Copilot Pulse.app/Contents/MacOS/CopilotPulse"
"$APP" --dump     # every session and its status
"$APP" --watch    # status changes as they happen
log show --last 10m --info --predicate 'subsystem == "com.asaf.CopilotPulse"' --style compact
```

Their output includes your session names and prompts, so remove anything private before you
share it in an issue.

## Contributing

Bug reports, ideas and pull requests are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) explains how
to build, test and try the app with made-up sessions. Please report security issues privately as
described in [SECURITY.md](SECURITY.md).

## License

Copyright © 2026 Asaf Manassen. Copilot Pulse is free software, licensed under the
[GNU General Public License v3.0 or later](LICENSE).

GitHub and GitHub Copilot are trademarks of GitHub, Inc.
