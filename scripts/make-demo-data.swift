// Creates a fake Copilot data directory with sessions in every state, for trying the app and for
// screenshots that don't show your own sessions:
//
//   swift scripts/make-demo-data.swift build/demo
//   COPILOT_PULSE_COPILOT_DIR=build/demo .build/debug/CopilotPulse
//
// `make demo` and `make screenshots` do both. All names and text are made up. Timestamps are
// relative to now, so the data is regenerated each time.
import Foundation
import SQLite3

let marker = ".copilot-pulse-demo"
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/demo", isDirectory: true)
    .standardizedFileURL
let fileManager = FileManager.default

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-demo-data: \(message)\n".utf8))
    exit(1)
}

// The directory is replaced, so refuse to touch anything this script didn't create (like ~/.copilot).
var isDirectory: ObjCBool = false
if fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) {
    guard isDirectory.boolValue else {
        fail("\(root.path) exists and isn't a directory, so it won't be replaced")
    }
    let contents: [String]
    do {
        contents = try fileManager.contentsOfDirectory(atPath: root.path)
    } catch {
        fail("couldn't check what's in \(root.path): \(error.localizedDescription)")
    }
    guard contents.isEmpty || contents.contains(marker) else {
        fail("\(root.path) exists and wasn't created by this script, so it won't be replaced")
    }
    do {
        try fileManager.removeItem(at: root)
    } catch {
        fail("couldn't remove the old demo data in \(root.path): \(error.localizedDescription)")
    }
}
try fileManager.createDirectory(at: root.appending(path: "session-state"), withIntermediateDirectories: true)
try Data().write(to: root.appending(path: marker))

let now = Date()
let minute: TimeInterval = 60
let hour: TimeInterval = 3_600
let day: TimeInterval = 86_400

func ago(_ seconds: TimeInterval) -> Date {
    now.addingTimeInterval(-seconds)
}

func iso(_ date: Date) -> String {
    date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
}

func json(_ object: Any) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
}

// MARK: - Event logs

/// Builds `events.jsonl` like the Copilot CLI writes it, including its top-level key order
/// (`type, data, id, timestamp, parentId`).
struct Log {
    private(set) var lines: [String] = []
    private var count = 0

    private mutating func add(_ type: String, _ data: [String: Any] = [:], raw: String? = nil, at date: Date) {
        let line = #"{"type":"\#(type)","data":\#(raw ?? json(data)),"id":"\#(UUID().uuidString.lowercased())","timestamp":"\#(iso(date))","parentId":null}"#
        lines.append(line)
    }

    private mutating func nextId(_ prefix: String) -> String {
        count += 1
        return "\(prefix)_\(count)"
    }

    /// A new session whose first turn starts with `prompt`.
    mutating func start(_ prompt: String, at date: Date) {
        add("session.start", ["producer": "copilot-agent", "version": 1], at: date)
        add("user.message", ["content": prompt], at: date.addingTimeInterval(1))
        add("assistant.turn_start", ["turnId": "0"], at: date.addingTimeInterval(2))
    }

    /// The agent calls a tool, which is still running unless `finished`.
    mutating func tool(
        _ name: String, _ arguments: [String: Any] = [:], title: String? = nil, at date: Date, finished: Bool = true
    ) {
        let id = nextId("call")
        let request: [String: Any] = ["toolCallId": id, "name": name, "arguments": arguments, "type": "function"]
        add("assistant.message", ["messageId": UUID().uuidString, "content": "", "toolRequests": [request]],
            at: date.addingTimeInterval(-1))
        var data: [String: Any] = ["toolCallId": id, "toolName": name, "arguments": arguments, "turnId": "0"]
        if let title { data["toolTitle"] = title }
        add("tool.execution_start", data, at: date)
        if finished {
            add("tool.execution_complete", raw: #"{"toolCallId":"\#(id)","success":true}"#, at: date.addingTimeInterval(3))
        }
    }

    mutating func permission(_ request: [String: Any], at date: Date) {
        add("permission.requested",
            ["requestId": nextId("permission"), "permissionRequest": request, "agentMode": "interactive"], at: date)
    }

    mutating func finish(_ summary: String, at date: Date) {
        add("assistant.message", ["messageId": UUID().uuidString, "content": summary, "toolRequests": [[String: Any]]()],
            at: date.addingTimeInterval(-1))
        add("session.task_complete", ["summary": summary, "success": true], at: date)
        add("assistant.turn_end", ["turnId": "0"], at: date.addingTimeInterval(1))
    }

    mutating func error(_ message: String, at date: Date) {
        add("session.error", ["errorType": "query", "message": message], at: date)
    }
}

// MARK: - Sessions

struct Session {
    var id: String
    var name: String
    var project: String?  // nil for a chat
    var branch = "main"
    var mode = "interactive"
    /// The app's "a turn is in progress" flag, which stays on while the agent waits for you.
    var running = false
    var createdAt: Date
    var updatedAt: Date
    /// Context-window tokens in use, and the model's limit.
    var context: (tokens: Int, limit: Int)
    var log: Log
}

var sessions: [Session] = []

func session(
    _ id: String, _ name: String, project: String?, branch: String = "main", mode: String = "interactive",
    running: Bool = false, started: Date, updated: Date? = nil, context: (Int, Int), _ build: (inout Log) -> Void
) {
    var log = Log()
    log.start(name, at: started)
    build(&log)
    sessions.append(Session(id: id, name: name, project: project, branch: branch, mode: mode, running: running,
                            createdAt: started, updatedAt: updated ?? started, context: context, log: log))
}

// Needs you: a question, a plan to approve and a permission prompt.
session("0b6c1f44-6a1e-4c55-9d0e-3f0a6f1c2a01", "Add dark mode to settings", project: "shop-web", branch: "dark-mode",
        running: true, started: ago(9 * minute), context: (46_000, 200_000)) { log in
    log.tool("view", ["path": "src/settings/SettingsPage.tsx"], at: ago(8 * minute))
    log.tool("ask_user", [
        "question": "Should dark mode follow the system appearance?",
        "choices": ["Yes, follow the system", "No, add a switch in settings", "Both, defaulting to the system"],
    ], at: ago(4 * minute), finished: false)
}
session("5d2e8a90-1f3b-4e7c-8a26-7b9c0d4e5f02", "Move sign-in to OAuth 2.1", project: "acme-api", branch: "oauth",
        mode: "plan", running: true, started: ago(14 * minute), context: (160_000, 272_000)) { log in
    log.tool("grep", ["pattern": "session_cookie"], at: ago(12 * minute))
    log.tool("exit_plan_mode", [
        "summary": "Replace cookie sessions with OAuth 2.1 and PKCE.",
    ], at: ago(2 * minute), finished: false)
}
session("9a4f2b17-c3d8-4e61-b5a0-2e8d7c6b4a03", "Release 2.4.0", project: "acme-api", branch: "release-2.4",
        running: true, started: ago(6 * minute), context: (31_000, 128_000)) { log in
    log.tool("bash", ["command": "npm version 2.4.0", "description": "Bump the version"], at: ago(5 * minute))
    log.tool("bash", ["command": "git push origin main --follow-tags", "description": "Push the release"],
             at: ago(1 * minute + 2), finished: false)
    log.permission(["kind": "shell", "fullCommandText": "git push origin main --follow-tags"], at: ago(1 * minute))
}

// Running: a project session and a chat.
session("3c7e9d21-8b4a-4f10-a6e2-5d1c0b9a8e04", "Fix flaky checkout test", project: "shop-web", branch: "fix-flaky-checkout",
        running: true, started: ago(7 * minute), context: (152_000, 200_000)) { log in
    log.tool("view", ["path": "tests/checkout.spec.ts"], at: ago(6 * minute))
    log.tool("bash", ["command": "for i in $(seq 20); do npm test -- checkout; done",
                      "description": "Run the checkout tests 20 times"],
             at: ago(40), finished: false)
}
session("e81b5c63-2d9f-4a7e-9c34-1f6a8b2d0c05", "When to use an actor instead of a lock?", project: nil,
        running: true, started: ago(25), context: (9_000, 200_000)) { log in
    log.tool("web_fetch", ["url": "https://docs.swift.org/swift-book/"], title: "Reading the Swift book",
             at: ago(10), finished: false)
}

// Done and stopped, recently enough to be highlighted.
session("6f0d3a85-4e2c-4b9a-8d17-9c5e2a1b3f06", "Update README screenshots", project: "website",
        started: ago(19 * minute), updated: ago(12 * minute), context: (88_000, 200_000)) { log in
    log.tool("bash", ["command": "make screenshots", "description": "Render the screenshots"], at: ago(17 * minute))
    log.finish("Replaced all four README screenshots.", at: ago(12 * minute))
}
session("b2a9e4c7-5f1d-4c38-a0b6-8e3d9f2c1a07", "Upgrade to Node 24", project: "shop-web", branch: "node-24",
        started: ago(26 * minute), updated: ago(20 * minute), context: (61_000, 128_000)) { log in
    log.tool("bash", ["command": "npm install", "description": "Install dependencies"], at: ago(24 * minute))
    log.error("Lost the connection to the model. Try again.", at: ago(20 * minute))
}

// Idle: ended a while ago.
session("47c1d8e2-9a3b-4f65-b8d0-6c2e1a9f4b08", "Set up CI", project: "website", branch: "ci",
        started: ago(3 * hour + 20 * minute), updated: ago(3 * hour), context: (54_000, 200_000)) { log in
    log.finish("Added a workflow that builds and deploys the site on every push to main.", at: ago(3 * hour))
}
session("d5e3a7b9-1c4f-4d82-9e6a-3b8f0c2d5e09", "Regex for semver tags", project: nil,
        started: ago(day + 2 * hour), updated: ago(day + 2 * hour - 90), context: (4_000, 200_000)) { log in
    log.finish("Use ^v(0|[1-9]\\d*)\\.(0|[1-9]\\d*)\\.(0|[1-9]\\d*)$ to match tags like v1.2.3.", at: ago(day + 2 * hour - 90))
}
session("8b2f6c4d-7e1a-4b93-a5c8-0d9e3f1b6a10", "Bump dependencies", project: "acme-api", branch: "deps",
        started: ago(2 * day + hour), updated: ago(2 * day), context: (132_000, 272_000)) { log in
    log.finish("Updated 14 packages to their latest minor versions. All tests pass.", at: ago(2 * day))
}

// MARK: - Files

for session in sessions {
    let directory = root.appending(path: "session-state/\(session.id)")
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(session.log.lines.map { $0 + "\n" }.joined().utf8).write(to: directory.appending(path: "events.jsonl"))
}

/// SQL string literal, or NULL.
func sql(_ value: String?) -> String {
    guard let value else { return "NULL" }
    return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
}

// Only the tables and columns Copilot Pulse reads from the app's database.
var statements = """
    CREATE TABLE projects (id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL);
    CREATE TABLE sessions (
        id TEXT PRIMARY KEY NOT NULL, title TEXT, session_type TEXT NOT NULL DEFAULT 'workspace', mode TEXT,
        is_running INTEGER NOT NULL DEFAULT 0, was_interrupted INTEGER NOT NULL DEFAULT 0,
        interruption_reason TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, archived_at TEXT);
    CREATE TABLE workspaces (
        id TEXT PRIMARY KEY NOT NULL, project_id TEXT NOT NULL, session_id TEXT, branch TEXT NOT NULL,
        name TEXT NOT NULL, creator_session_id TEXT, archived_at TEXT, updated_at TEXT NOT NULL);
    CREATE TABLE activity_items (
        id TEXT PRIMARY KEY NOT NULL, session_id TEXT, activity_type TEXT NOT NULL,
        preview TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL);
    CREATE TABLE app_state (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL, updated_at TEXT NOT NULL);
    CREATE TABLE session_context_usage (
        id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL, ts_ms INTEGER NOT NULL,
        current_tokens INTEGER NOT NULL, token_limit INTEGER NOT NULL);

    """
for project in Set(sessions.compactMap(\.project)).sorted() {
    statements += "INSERT INTO projects (id, name) VALUES (\(sql("project-\(project)")), \(sql(project)));\n"
}
for (index, session) in sessions.enumerated() {
    statements += """
        INSERT INTO sessions (id, title, session_type, mode, is_running, created_at, updated_at)
        VALUES (\(sql(session.id)), \(sql(session.name)), \(sql(session.project == nil ? "general_chat" : "project")),
                \(sql(session.mode)), \(session.running ? 1 : 0), \(sql(iso(session.createdAt))), \(sql(iso(session.updatedAt))));
        INSERT INTO session_context_usage (session_id, ts_ms, current_tokens, token_limit)
        VALUES (\(sql(session.id)), \(Int(session.updatedAt.timeIntervalSince1970 * 1_000)), \(session.context.tokens),
                \(session.context.limit));

        """
    if let project = session.project {
        statements += """
            INSERT INTO workspaces (id, project_id, session_id, branch, name, updated_at)
            VALUES (\(sql("workspace-\(index + 1)")), \(sql("project-\(project)")), \(sql(session.id)),
                    \(sql(session.branch)), \(sql(session.name)), \(sql(iso(session.updatedAt))));

            """
    }
}

var database: OpaquePointer?
guard sqlite3_open(root.appending(path: "data.db").path, &database) == SQLITE_OK else {
    fail("couldn't create data.db")
}
var message: UnsafeMutablePointer<CChar>?
guard sqlite3_exec(database, "BEGIN;\n" + statements + "COMMIT;", nil, nil, &message) == SQLITE_OK else {
    fail(message.map { String(cString: $0) } ?? "SQLite error")
}
sqlite3_close(database)

print("Created \(sessions.count) demo sessions in \(root.path)")
