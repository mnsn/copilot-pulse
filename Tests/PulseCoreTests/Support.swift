import Foundation
import SQLite3
import Synchronization
import Testing
@testable import PulseCore

/// Fixed reference time for fixtures: 2026-10-18T10:00:00Z.
let referenceDate = Date(timeIntervalSince1970: 1_792_317_600)

/// The reference time plus `seconds`.
func t(_ seconds: TimeInterval) -> Date {
    referenceDate.addingTimeInterval(seconds)
}

/// The CLI's timestamp format, e.g. `2026-10-18T10:00:01.000Z`.
func iso(_ date: Date) -> String {
    date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
}

struct TestError: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}

// MARK: - Event log lines

/// Builds `events.jsonl` lines shaped like the Copilot CLI's, including its top-level key order
/// (`type, data, [agentId], id, timestamp, parentId`) that the parser's fast paths rely on.
enum Line {
    static func event(_ type: String, data: [String: Any] = [:], at date: Date, agentId: String? = nil) -> String {
        event(type, rawData: json(data), at: date, agentId: agentId)
    }

    static func event(_ type: String, rawData: String, at date: Date, agentId: String? = nil) -> String {
        var line = #"{"type":"\#(type)","data":\#(rawData)"#
        if let agentId {
            line += #","agentId":"\#(agentId)""#
        }
        line += #","id":"\#(UUID().uuidString.lowercased())","timestamp":"\#(iso(date))","parentId":null}"#
        return line
    }

    static func json(_ object: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    static func sessionStart(at date: Date) -> String {
        event("session.start", data: ["sessionId": "session", "version": 1, "producer": "copilot-agent"], at: date)
    }

    static func userMessage(_ content: String = "Please fix the bug", at date: Date, agentId: String? = nil) -> String {
        event("user.message", data: ["content": content], at: date, agentId: agentId)
    }

    static func turnStart(at date: Date, subagent: Bool = false) -> String {
        event("assistant.turn_start", data: tagged(["turnId": "0"], subagent), at: date)
    }

    static func turnEnd(at date: Date, subagent: Bool = false) -> String {
        event("assistant.turn_end", data: tagged(["turnId": "0"], subagent), at: date)
    }

    static func assistantMessage(toolCalls: [String] = [], at date: Date, subagent: Bool = false) -> String {
        let requests: [[String: Any]] = toolCalls.map {
            ["toolCallId": $0, "name": "bash", "arguments": [String: Any](), "type": "function"]
        }
        let data: [String: Any] = ["messageId": UUID().uuidString, "content": "Working on it", "toolRequests": requests]
        return event("assistant.message", data: tagged(data, subagent), at: date)
    }

    static func toolStart(
        _ name: String, id: String, arguments: [String: Any] = [:], title: String? = nil,
        at date: Date, subagent: Bool = false
    ) -> String {
        var data: [String: Any] = ["toolCallId": id, "toolName": name, "arguments": arguments, "turnId": "0"]
        if let title { data["toolTitle"] = title }
        return event("tool.execution_start", data: tagged(data, subagent), at: date)
    }

    /// `toolCallId` first, as the CLI writes it, plus a nested timestamp that must not be
    /// mistaken for the event's own.
    static func toolComplete(id: String, at date: Date) -> String {
        let data = #"{"toolCallId":"\#(id)","success":true,"result":{"content":"ok","timestamp":"2001-01-01T00:00:00.000Z"}}"#
        return event("tool.execution_complete", rawData: data, at: date)
    }

    static func permissionRequested(id: String, _ request: [String: Any], at date: Date) -> String {
        let data: [String: Any] = ["requestId": id, "permissionRequest": request, "agentMode": "interactive"]
        return event("permission.requested", data: data, at: date)
    }

    static func permissionCompleted(id: String, at date: Date) -> String {
        event("permission.completed", data: ["requestId": id, "result": ["kind": "approved"]], at: date)
    }

    static func hook(_ hookType: String, at date: Date, agentId: String? = nil) -> String {
        let input: [String: Any] = ["stopReason": "end_turn", "timestamp": 1_791_110_203_986]
        let data: [String: Any] = ["hookInvocationId": "hook", "hookType": hookType, "input": input]
        return event("hook.start", data: data, at: date, agentId: agentId)
    }

    static func abort(_ reason: String = "user_initiated", at date: Date) -> String {
        event("abort", data: ["reason": reason], at: date)
    }

    static func sessionError(_ message: String, at date: Date) -> String {
        event("session.error", data: ["errorType": "query", "message": message], at: date)
    }

    static func taskComplete(_ summary: String, at date: Date) -> String {
        event("session.task_complete", data: ["summary": summary, "success": true], at: date)
    }

    static func shutdown(at date: Date) -> String {
        event("session.shutdown", data: ["shutdownType": "routine"], at: date)
    }

    /// A cold resume by default. Otherwise it keeps the previous process's pending work waiting,
    /// or joins a turn another client is running.
    static func resume(keepingPendingWork: Bool = false, joiningLiveWork: Bool = false, at date: Date) -> String {
        var data: [String: Any] = [
            "resumeTime": iso(date), "eventCount": 12, "alreadyInUse": joiningLiveWork, "sessionWasActive": joiningLiveWork,
        ]
        if keepingPendingWork { data["continuePendingWork"] = true }
        return event("session.resume", data: data, at: date)
    }

    /// An irrelevant event of roughly `bytes` length, standing in for big tool output or images.
    static func filler(bytes: Int, at date: Date) -> String {
        event("session.binary_asset", data: ["data": String(repeating: "A", count: max(0, bytes - 160))], at: date)
    }

    private static func tagged(_ data: [String: Any], _ subagent: Bool) -> [String: Any] {
        guard subagent else { return data }
        var data = data
        data["parentToolCallId"] = "toolu_parent"
        return data
    }
}

/// Replays lines through the parser and reducer, as `EventLogReader` does.
func logState(_ lines: [String]) -> SessionLogState {
    var state = SessionLogState()
    for line in lines {
        if let event = EventLineParser.parse(line) {
            state.apply(event)
        }
    }
    return state
}

// MARK: - Files

func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("CopilotPulseTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    // FSEvents reports resolved paths (/private/var/…), so use that form throughout.
    return url.resolvingSymlinksInPath()
}

func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let url = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(url)
}

func writeLog(_ lines: [String], to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: url)
}

func appendLog(_ lines: [String], to url: URL) throws {
    try appendRaw(lines.map { $0 + "\n" }.joined(), to: url)
}

func appendRaw(_ text: String, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
}

// MARK: - Database

/// SQL string literal, or NULL.
func sql(_ value: String?) -> String {
    guard let value else { return "NULL" }
    return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
}

/// A stand-in for the Copilot app's `data.db` with only the tables and columns Copilot Pulse reads.
/// It writes through its own connection, like the app does while Copilot Pulse reads.
///
/// Tests that write while the engine reads must use WAL, as the app does. With a rollback journal,
/// a write that overlaps a read fails with "database is locked", or with "disk I/O error"
/// (`SQLITE_IOERR_LOCK`) next to a read-only connection in the same process.
final class TestDatabase {
    private var handle: OpaquePointer?

    init(at url: URL, journalMode: String = "DELETE") throws {
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else {
            throw TestError("Could not create \(url.path)")
        }
        try exec("PRAGMA journal_mode=\(journalMode);")
    }

    deinit {
        close()
    }

    func close() {
        if let handle {
            sqlite3_close(handle)
        }
        handle = nil
    }

    func exec(_ statements: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, statements, nil, nil, &message) == SQLITE_OK else {
            defer { sqlite3_free(message) }
            let text = message.map { String(cString: $0) } ?? "SQLite error"
            throw TestError("\(text) (code \(sqlite3_extended_errcode(handle)), errno \(sqlite3_system_errno(handle)))")
        }
    }

    static let appSchema = """
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

    func createAppSchema() throws {
        try exec(Self.appSchema)
    }

    func addProject(_ id: String, name: String) throws {
        try exec("INSERT INTO projects (id, name) VALUES (\(sql(id)), \(sql(name)));")
    }

    func addSession(
        _ id: String, title: String?, type: String = "project", mode: String? = nil, running: Bool = false,
        interrupted: Bool = false, reason: String? = nil, updatedAt: Date = t(0), archived: Bool = false
    ) throws {
        try exec("""
            INSERT INTO sessions (id, title, session_type, mode, is_running, was_interrupted, interruption_reason,
                                  created_at, updated_at, archived_at)
            VALUES (\(sql(id)), \(sql(title)), \(sql(type)), \(sql(mode)), \(running ? 1 : 0), \(interrupted ? 1 : 0),
                    \(sql(reason)), \(sql(iso(t(-86_400)))), \(sql(iso(updatedAt))), \(archived ? sql(iso(updatedAt)) : "NULL"));
            """)
    }

    func addWorkspace(
        _ id: String, session: String, project: String = "p1", name: String, branch: String = "main",
        creator: String? = nil, archived: Bool = false, updatedAt: Date = t(0)
    ) throws {
        try exec("""
            INSERT INTO workspaces (id, project_id, session_id, branch, name, creator_session_id, archived_at, updated_at)
            VALUES (\(sql(id)), \(sql(project)), \(sql(session)), \(sql(branch)), \(sql(name)), \(sql(creator)),
                    \(archived ? sql(iso(updatedAt)) : "NULL"), \(sql(iso(updatedAt))));
            """)
    }

    func addActivity(session: String, type: String, preview: String, at date: Date) throws {
        try exec("""
            INSERT INTO activity_items (id, session_id, activity_type, preview, created_at)
            VALUES (\(sql(UUID().uuidString)), \(sql(session)), \(sql(type)), \(sql(preview)), \(sql(iso(date))));
            """)
    }

    func setAppState(_ key: String, _ value: String, at date: Date) throws {
        try exec("""
            INSERT OR REPLACE INTO app_state (key, value, updated_at) VALUES (\(sql(key)), \(sql(value)), \(sql(iso(date))));
            """)
    }

    func addContextUsage(session: String, tokens: Int, limit: Int, at date: Date) throws {
        try exec("""
            INSERT INTO session_context_usage (session_id, ts_ms, current_tokens, token_limit)
            VALUES (\(sql(session)), \(Int(date.timeIntervalSince1970 * 1_000)), \(tokens), \(limit));
            """)
    }
}

// MARK: - Engine

/// Collects engine publications (delivered on the engine's queue) for async assertions.
final class SnapshotCollector: Sendable {
    private let snapshots = Mutex<[EngineSnapshot]>([])

    func add(_ snapshot: EngineSnapshot) {
        snapshots.withLock { $0.append(snapshot) }
    }

    var count: Int {
        snapshots.withLock { $0.count }
    }

    /// Waits until the latest snapshot satisfies `predicate`.
    @discardableResult
    func wait(
        _ what: String, timeout: Duration = .seconds(15), until predicate: (EngineSnapshot) -> Bool
    ) async throws -> EngineSnapshot {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let latest = snapshots.withLock({ $0.last }), predicate(latest) {
                return latest
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let (count, latest) = snapshots.withLock { ($0.count, $0.last) }
        throw TestError(
            "Timed out waiting for \(what) after \(count) snapshot(s); latest: \(latest.map { String(describing: $0) } ?? "none")"
        )
    }
}
