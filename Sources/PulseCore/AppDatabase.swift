import Foundation
import SQLite3

/// A session as listed by the Copilot app (from its own `data.db`).
public struct SessionMeta: Sendable, Equatable, Codable {
    public var id: String
    public var name: String
    /// `project`, `general_chat`, … (as stored by the app).
    public var sessionType: String
    public var mode: String?
    /// The app's own "a turn is in progress" flag (also true while waiting on `ask_user`).
    /// Nil when unknown: the fallback query and the folder scan can't read it.
    public var isRunning: Bool?
    public var wasInterrupted: Bool
    public var interruptionReason: String?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var projectName: String?
    public var branch: String?
    public var creatorSessionId: String?
    /// The app's workspace for project sessions (its unread markers are keyed by this).
    public var workspaceId: String?
    /// Latest entry in the app's activity feed for this session.
    public var lastActivity: ActivityPreview?

    public init(
        id: String, name: String, sessionType: String = "project", mode: String? = nil,
        isRunning: Bool? = false, wasInterrupted: Bool = false, interruptionReason: String? = nil,
        createdAt: Date? = nil, updatedAt: Date? = nil, projectName: String? = nil,
        branch: String? = nil, creatorSessionId: String? = nil, workspaceId: String? = nil,
        lastActivity: ActivityPreview? = nil
    ) {
        self.id = id
        self.name = name
        self.sessionType = sessionType
        self.mode = mode
        self.isRunning = isRunning
        self.wasInterrupted = wasInterrupted
        self.interruptionReason = interruptionReason
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.projectName = projectName
        self.branch = branch
        self.creatorSessionId = creatorSessionId
        self.workspaceId = workspaceId
        self.lastActivity = lastActivity
    }

    public var isChat: Bool { sessionType == "general_chat" }
}

public enum AppDatabaseError: Error, CustomStringConvertible {
    case open(String, code: Int32)
    case query(String, code: Int32)

    public var description: String {
        switch self {
        case .open(let message, _): return "Could not open Copilot database: \(message)"
        case .query(let message, _): return "Copilot database query failed: \(message)"
        }
    }

    /// SQLite's primary result code.
    var code: Int32 {
        switch self {
        case .open(_, let code), .query(_, let code): return code & 0xFF
        }
    }
}

/// An entry from the app's own activity feed (`agent_idle`, `agent_asking`, `agent_error`, …).
public struct ActivityPreview: Sendable, Equatable, Codable {
    public var kind: String
    public var text: String
    public var at: Date?

    public init(kind: String, text: String, at: Date?) {
        self.kind = kind
        self.text = text
        self.at = at
    }
}

/// What the Copilot app itself shows: which workspaces carry an unread dot, and which session is on screen.
public struct AppViewState: Sendable, Equatable {
    /// Workspace IDs with an unread marker; nil when the app's format couldn't be read.
    public var unreadWorkspaceIds: Set<String>?
    public var unreadUpdatedAt: Date?
    /// The session the app's window is currently showing, if it could be determined.
    public var viewedSessionId: String?

    public init(unreadWorkspaceIds: Set<String>? = nil, unreadUpdatedAt: Date? = nil, viewedSessionId: String? = nil) {
        self.unreadWorkspaceIds = unreadWorkspaceIds
        self.unreadUpdatedAt = unreadUpdatedAt
        self.viewedSessionId = viewedSessionId
    }
}

public struct DatabaseSnapshot: Sendable, Equatable {
    public var sessions: [SessionMeta]
    public var view: AppViewState
}

/// Read-only access to the Copilot app's SQLite database.
public enum AppDatabase {
    /// Sessions the app shows: unarchived chats, plus project sessions with a live workspace.
    /// The workspace name (what the sidebar shows) wins over the session title.
    static let visibleSessionsQuery = """
        SELECT s.id,
               COALESCE(NULLIF(TRIM(w.name), ''), NULLIF(TRIM(s.title), ''), '') AS name,
               s.session_type, s.mode, s.is_running, s.was_interrupted, s.interruption_reason,
               s.created_at, s.updated_at, p.name, w.branch, w.creator_session_id, w.id
        FROM sessions s
        LEFT JOIN workspaces w ON w.id = (
            SELECT w2.id FROM workspaces w2
            WHERE w2.session_id = s.id
            ORDER BY (w2.archived_at IS NULL) DESC, w2.updated_at DESC
            LIMIT 1)
        LEFT JOIN projects p ON p.id = w.project_id
        WHERE s.archived_at IS NULL
          AND (s.session_type = 'general_chat' OR (w.id IS NOT NULL AND w.archived_at IS NULL))
        """

    /// Used if a future app version changes the schema the main query depends on.
    static let fallbackQuery = """
        SELECT id, COALESCE(NULLIF(TRIM(title), ''), ''), session_type, updated_at
        FROM sessions
        WHERE archived_at IS NULL
        ORDER BY updated_at DESC
        LIMIT 60
        """

    static let latestActivityQuery = """
        SELECT a.session_id, a.activity_type, a.preview, a.created_at
        FROM activity_items a
        JOIN (SELECT session_id, MAX(created_at) AS latest
              FROM activity_items WHERE session_id IS NOT NULL GROUP BY session_id) l
          ON l.session_id = a.session_id AND l.latest = a.created_at
        """

    static let viewStateQuery = """
        SELECT key, value, updated_at FROM app_state WHERE key IN ('workspace-unread', 'lastRoutePath')
        """

    public static func loadVisibleSessions(at url: URL) throws -> [SessionMeta] {
        try load(at: url).sessions
    }

    /// Sessions plus the app's view state. Only the session list is required; the rest is best effort.
    public static func load(at url: URL) throws -> DatabaseSnapshot {
        do {
            return try load(from: Connection(readOnly: url))
        } catch let error as AppDatabaseError where error.code == SQLITE_CANTOPEN && isClosedWALDatabase(url) {
            // A read-only connection can't recreate the write-ahead log, which SQLite removes when
            // the app closes the database. Without a log or journal, the file holds every committed
            // change, and the app only writes to it again through a new log, so read it as it is.
            guard let snapshot = try? load(from: Connection(readOnly: url, immutable: true)) else { throw error }
            return snapshot
        }
    }

    private static func isClosedWALDatabase(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: url.path)
            && !fileManager.fileExists(atPath: url.path + "-wal")
            && !fileManager.fileExists(atPath: url.path + "-journal")
    }

    private static func load(from connection: Connection) throws -> DatabaseSnapshot {
        var sessions = try loadSessions(connection)

        if let latest = try? connection.rows(latestActivityQuery, { row in
            (row.text(0) ?? "", ActivityPreview(kind: row.text(1) ?? "", text: row.text(2) ?? "", at: row.date(3)))
        }) {
            let bySession = Dictionary(latest, uniquingKeysWith: { first, _ in first })
            for index in sessions.indices {
                sessions[index].lastActivity = bySession[sessions[index].id]
            }
        }

        var view = AppViewState()
        if let entries = try? connection.rows(viewStateQuery, { row in (row.text(0) ?? "", row.text(1) ?? "", row.date(2)) }) {
            for (key, value, updatedAt) in entries {
                switch key {
                case "workspace-unread":
                    if let ids = parseStringArray(value) {
                        view.unreadWorkspaceIds = Set(ids)
                        view.unreadUpdatedAt = updatedAt
                    }
                case "lastRoutePath":
                    view.viewedSessionId = sessionId(inRoute: value, sessions: sessions)
                default:
                    break
                }
            }
        }
        return DatabaseSnapshot(sessions: sessions, view: view)
    }

    private static func loadSessions(_ connection: Connection) throws -> [SessionMeta] {
        do {
            return try connection.rows(visibleSessionsQuery) { row in
                SessionMeta(
                    id: row.text(0) ?? "",
                    name: row.text(1) ?? "",
                    sessionType: row.text(2) ?? "",
                    mode: row.text(3),
                    isRunning: row.bool(4),
                    wasInterrupted: row.bool(5),
                    interruptionReason: row.text(6),
                    createdAt: row.date(7),
                    updatedAt: row.date(8),
                    projectName: row.text(9),
                    branch: row.text(10),
                    creatorSessionId: row.text(11),
                    workspaceId: row.text(12)
                )
            }.filter { !$0.id.isEmpty }
        } catch {
            return try connection.rows(fallbackQuery) { row in
                SessionMeta(
                    id: row.text(0) ?? "",
                    name: row.text(1) ?? "",
                    sessionType: row.text(2) ?? "",
                    isRunning: nil,
                    updatedAt: row.date(3)
                )
            }.filter { !$0.id.isEmpty }
        }
    }

    static func parseStringArray(_ json: String) -> [String]? {
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return nil }
        let strings = array.compactMap { $0 as? String }
        return strings.count == array.count ? strings : nil
    }

    /// Routes look like `/chats/<session id>`; project routes may use the workspace ID instead,
    /// so any UUID in the path is matched against both.
    static func sessionId(inRoute route: String, sessions: [SessionMeta]) -> String? {
        let pattern = /[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/
        for match in route.matches(of: pattern) {
            let candidate = String(match.output).lowercased()
            if let session = sessions.first(where: { $0.id.lowercased() == candidate || $0.workspaceId?.lowercased() == candidate }) {
                return session.id
            }
        }
        return nil
    }
}

/// Short-lived, read-only SQLite connection. It never changes the database's contents. Like any
/// reader alongside the app's WAL writer, it takes brief shared locks and updates SQLite's
/// shared-memory index (`-shm`).
final class Connection {
    private let handle: OpaquePointer

    /// `immutable` reads the file without any locks or `-wal`/`-shm` files. Only use it while
    /// nothing can write to the file.
    init(readOnly url: URL, immutable: Bool = false) throws {
        var db: OpaquePointer?
        var flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        var filename = url.path
        if immutable {
            flags |= SQLITE_OPEN_URI
            filename = url.standardizedFileURL.absoluteString + "?immutable=1"
        }
        let status = sqlite3_open_v2(filename, &db, flags, nil)
        guard status == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite status \(status)"
            if let db { sqlite3_close(db) }
            throw AppDatabaseError.open(message, code: status)
        }
        handle = db
        sqlite3_busy_timeout(db, 2_000)
    }

    deinit {
        sqlite3_close(handle)
    }

    func rows<T>(_ sql: String, _ map: (Row) -> T) throws -> [T] {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else {
            throw AppDatabaseError.query(String(cString: sqlite3_errmsg(handle)), code: prepared)
        }
        defer { sqlite3_finalize(statement) }
        var result: [T] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else {
                throw AppDatabaseError.query(String(cString: sqlite3_errmsg(handle)), code: status)
            }
            result.append(map(Row(statement: statement)))
        }
        return result
    }
}

struct Row {
    let statement: OpaquePointer

    func text(_ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, column)
        else { return nil }
        return String(cString: pointer)
    }

    func bool(_ column: Int32) -> Bool {
        sqlite3_column_int64(statement, column) != 0
    }

    /// ISO-8601 text today; numeric epoch (seconds or milliseconds) is accepted defensively.
    func date(_ column: Int32) -> Date? {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER, SQLITE_FLOAT:
            let value = sqlite3_column_double(statement, column)
            return Date(timeIntervalSince1970: value > 100_000_000_000 ? value / 1_000 : value)
        case SQLITE_TEXT:
            return text(column).flatMap(Timestamp.parse)
        default:
            return nil
        }
    }
}
