# Changelog

## 0.2.0 - 2026-10-20

- **Updates**: Copilot Pulse now updates itself, with [Sparkle](https://sparkle-project.org). The
  second time you open it, it asks whether to check for updates automatically, once a day.
  **Check for Updates…** in its settings checks right away. It installs only updates that come from
  this project's GitHub releases and are signed with the project's key.
- **If you have 0.1.0**: it can't update itself. Download this version by hand once, as described
  in [Install](https://github.com/mnsn/copilot-pulse#install), and replace the app. Later versions
  arrive on their own.
- **Menu bar**: the done and stopped counts now show their check mark and exclamation mark,
  instead of a plain green dot and a plain red triangle.
- **Private**: the only network requests are the update checks and downloads, from GitHub. Nothing
  about your sessions is sent.

## 0.1.0 - 2026-10-19

The first release.

- **Menu bar**: the Copilot Pulse icon with a count for each group of GitHub Copilot app
  sessions: needs you (a question, a plan to approve or a permission prompt), running, done and
  stopped. Click it to see every session by group.
- **Desktop widget**: an optional widget-style panel in three sizes, on the desktop behind your
  windows or floating above them.
- **One click to a session**: click any session to open it in the Copilot app.
- **Instant**: driven by file-system events, with no hooks to install and no polling.
- **Private**: reads the Copilot app's files under `~/.copilot` read-only, and makes no network
  connections.
- A universal app for Apple silicon and Intel Macs with macOS 15 or later.
