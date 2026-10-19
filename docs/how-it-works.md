# How Copilot Pulse works

## Where the data comes from

The Copilot app already records everything needed, in two places under `~/.copilot`:

| Source | Written by | Provides |
|---|---|---|
| `data.db` (SQLite, WAL mode) | the Copilot app | sessions, names, projects/branches, the "is running" flag, unread markers, the activity feed |
| `session-state/<id>/events.jsonl` | the Copilot agent | a step-by-step log: turns, tool calls, questions, plans, permission prompts, errors |

Copilot Pulse combines the two. The database says which sessions exist and whether the app
thinks they're running. The tail of each log says exactly where a session is, for example
"asked a question at 14:02 and is still waiting".

Both are opened **read-only**. The database uses SQLite's read-only mode, and for the logs only
newly appended bytes are read.

## How a status is decided

The [states table in the README](../README.md#what-the-states-mean) lists every status and when
it applies. A few more details:

- "Needs you" sorts the longest-waiting session first; the other groups show the most recent
  first.
- **Done** and **Stopped** sessions stay highlighted until you've seen them. That happens when:
  - you open the session from Copilot Pulse, or click **Clear** on its group in the menu-bar
    panel,
  - you're looking at it in the Copilot app (the app is frontmost and showing that session),
  - the Copilot app clears its own unread marker for the session's workspace, or
  - the **Keep Finished Sessions For** time passes (1 hour by default).

  After that, the session moves to Idle.
- Detailed states (questions, plans, permissions, the current step) come from the agent's log on
  this Mac. A session without a local log only shows Running, Interrupted or Idle, based on the
  app's own flags.
- Clicking a session opens it through the Copilot app's `ghapp://sessions/<id>` link.

## Updates are pushed, not polled

- **Agent logs** are watched with **FSEvents**. The agent closes `events.jsonl` after every
  append, so each write produces an event (about 0.15 s latency).
- **The app's database** is watched with **kqueue** on `data.db-wal`. This was a key finding:
  FSEvents only reports a file's content changes once the writer **closes** it. The Copilot app
  keeps its SQLite connection open, so its writes to `data.db-wal` produce no FSEvents at all,
  even though the file changes. A kqueue `EVFILT_VNODE` watch reports every write immediately.
  Bursts (one tool call causes about 10 writes) are combined into one reload after 0.25 s.
  When the app quits and SQLite deletes the WAL file, the watch is re-armed as soon as the file
  is recreated. `data.db` itself is deliberately not opened for watching: closing an extra file
  descriptor on a SQLite database drops the process's SQLite locks.

On real data, a session rename (a database-only change) reached the UI about 0.26 s after the
app wrote it.

Two timers exist, and neither drives status updates:

- a 15 s tick that refreshes relative times ("3m") and expires the "keep finished" window, and
- a 60 s safety rescan that catches anything missed, for example after the Mac wakes from sleep.

## Why not a WidgetKit widget?

WidgetKit widgets are drawn by the system from a timeline, and the system **budgets** how often
they can reload. Per Apple's [Keeping a widget up to date](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date),
a frequently viewed widget typically gets 40–70 refreshes a day, "roughly every 15 to 60 minutes".
That is the delay you see with polling-based widgets.

- `WidgetCenter.reloadAllTimelines()` doesn't avoid that. A reload requested by a background app
  counts against the budget. The exceptions are narrow, such as the containing app being in the
  foreground.
- [Widget push updates](https://developer.apple.com/documentation/widgetkit/updating-widgets-with-widgetkit-push-notifications)
  through APNs are "budgeted … and delivered opportunistically" as well. They also need a server,
  push entitlements and a paid developer account.
- Third-party widget hosts such as Pushcut or Scriptable are WidgetKit widgets themselves, so they
  have the same limit. Shortcuts and App Intents run from a script don't avoid it either.

Copilot hooks aren't needed: the app and the agent already write every state change to disk,
so watching those files sees changes without changing any Copilot configuration.

So Copilot Pulse uses a different approach: a borderless, non-activating panel drawn by the app
itself. It sits at desktop level (behind windows, on every Space) and is styled like a macOS
widget. A running app can redraw its own window whenever it likes, so there is no refresh budget.

The trade-offs:

- it isn't in the system widget gallery or Notification Center,
- it doesn't follow the desktop widget tinting, and
- the app must be running (that's what Launch at Login is for).

A WidgetKit extension also needs Xcode to build, and this project builds with the Command Line
Tools alone.

## When the Copilot app's files change

This relies on the Copilot app's **undocumented** local files: the database schema, the event
log format, and the `ghapp://` link. An app update could change them.

- If the main database query fails, the app uses a simpler one: session names only, without the
  running flag, projects or branches.
- If the database can't be read at all, sessions are listed from their log folders, and the
  problem is shown in the panel and the widget.
