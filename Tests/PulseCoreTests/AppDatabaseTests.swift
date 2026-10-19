import Foundation
import Testing
@testable import PulseCore

@Suite struct AppDatabaseTests {
    static let sessionId = "11111111-1111-4111-8111-111111111111"
    static let workspaceId = "22222222-2222-4222-8222-222222222222"
    static let chatId = "33333333-3333-4333-8333-333333333333"

    @Test(arguments: [
        (#"["a","b"]"#, ["a", "b"]),
        ("[]", []),
        (#"["a",1]"#, nil),
        (#"{"a":1}"#, nil),
        ("not json", nil),
        ("", nil),
    ] as [(String, [String]?)])
    func parsesStringArrays(_ json: String, _ expected: [String]?) {
        #expect(AppDatabase.parseStringArray(json) == expected)
    }

    @Test func findsTheSessionOnScreen() {
        let sessions = [
            SessionMeta(id: Self.sessionId, name: "Project", workspaceId: Self.workspaceId),
            SessionMeta(id: Self.chatId, name: "Chat", sessionType: "general_chat"),
        ]
        func viewed(_ route: String) -> String? {
            AppDatabase.sessionId(inRoute: route, sessions: sessions)
        }
        #expect(viewed("/chats/\(Self.chatId)") == Self.chatId)
        #expect(viewed("/chats/\(Self.chatId.uppercased())") == Self.chatId)
        #expect(viewed("/workspaces/\(Self.workspaceId)/session") == Self.sessionId)
        #expect(viewed("/projects/99999999-9999-4999-8999-999999999999/chats/\(Self.chatId)") == Self.chatId)
        #expect(viewed("/settings") == nil)
        #expect(viewed("") == nil)
    }

    @Test func loadsWhatTheAppShows() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("data.db")
            let db = try TestDatabase(at: url, journalMode: "WAL")
            defer { db.close() }
            try db.createAppSchema()
            try db.addProject("p1", name: "acme-web")

            // A project session: its live workspace's (sidebar) name wins over the session title.
            try db.addSession(Self.sessionId, title: "Session title", mode: "autopilot", running: true, updatedAt: t(10))
            try db.addWorkspace(
                "old-workspace", session: Self.sessionId, name: "Old", branch: "old", archived: true, updatedAt: t(20)
            )
            try db.addWorkspace(
                Self.workspaceId, session: Self.sessionId, name: "  Fix login  ", branch: "fix-login",
                creator: "parent-session", updatedAt: t(5)
            )
            // Chats have no workspace.
            try db.addSession(
                Self.chatId, title: "  Quick question ", type: "general_chat", interrupted: true, reason: "app_quit",
                updatedAt: t(30)
            )
            try db.addSession("untitled-chat", title: nil, type: "general_chat")
            // Not shown by the app.
            try db.addSession("archived", title: "Archived", archived: true)
            try db.addWorkspace("w-archived", session: "archived", name: "Archived")
            try db.addSession("workspace-archived", title: "Gone")
            try db.addWorkspace("w-gone", session: "workspace-archived", name: "Gone", archived: true)
            try db.addSession("no-workspace", title: "Orphan")

            try db.addActivity(session: Self.sessionId, type: "agent_asking", preview: "Older", at: t(1))
            try db.addActivity(session: Self.sessionId, type: "agent_idle", preview: "Latest", at: t(9))
            try db.setAppState("workspace-unread", "[\"\(Self.workspaceId)\"]", at: t(40))
            try db.setAppState("lastRoutePath", "/chats/\(Self.chatId)", at: t(41))

            let snapshot = try AppDatabase.load(at: url)
            let sessions = Dictionary(uniqueKeysWithValues: snapshot.sessions.map { ($0.id, $0) })
            #expect(sessions.keys.sorted() == [Self.sessionId, Self.chatId, "untitled-chat"].sorted())

            #expect(sessions[Self.sessionId] == SessionMeta(
                id: Self.sessionId, name: "Fix login", sessionType: "project", mode: "autopilot", isRunning: true,
                createdAt: t(-86_400), updatedAt: t(10), projectName: "acme-web", branch: "fix-login",
                creatorSessionId: "parent-session", workspaceId: Self.workspaceId,
                lastActivity: ActivityPreview(kind: "agent_idle", text: "Latest", at: t(9))
            ))
            #expect(sessions[Self.chatId] == SessionMeta(
                id: Self.chatId, name: "Quick question", sessionType: "general_chat", wasInterrupted: true,
                interruptionReason: "app_quit", createdAt: t(-86_400), updatedAt: t(30)
            ))
            #expect(sessions["untitled-chat"]?.name == "")
            #expect(snapshot.view == AppViewState(
                unreadWorkspaceIds: [Self.workspaceId], unreadUpdatedAt: t(40), viewedSessionId: Self.chatId
            ))
        }
    }

    @Test func readsAlongsideTheAppsWriter() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("data.db")
            let db = try TestDatabase(at: url, journalMode: "WAL")
            defer { db.close() }
            try db.createAppSchema()
            try db.addSession(Self.chatId, title: "Committed", type: "general_chat")

            // The app is mid-write: readers must neither wait for nor see the uncommitted row.
            try db.exec("BEGIN IMMEDIATE;")
            try db.addSession("pending", title: "Uncommitted", type: "general_chat")
            var during: DatabaseSnapshot?
            let elapsed = try ContinuousClock().measure { during = try AppDatabase.load(at: url) }
            #expect(during?.sessions.map(\.id) == [Self.chatId])
            #expect(elapsed < .seconds(1))

            try db.exec("COMMIT;")
            #expect(try AppDatabase.load(at: url).sessions.map(\.id).sorted() == [Self.chatId, "pending"].sorted())
        }
    }

    @Test func fallsBackToAMinimalQueryWhenTheSchemaChanges() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("data.db")
            let db = try TestDatabase(at: url)
            defer { db.close() }
            try db.exec("""
                CREATE TABLE sessions (id TEXT PRIMARY KEY, title TEXT, session_type TEXT, updated_at TEXT, archived_at TEXT);
                INSERT INTO sessions VALUES ('a', '  Alpha ', 'project', \(sql(iso(t(1)))), NULL);
                INSERT INTO sessions VALUES ('b', NULL, 'general_chat', \(sql(iso(t(2)))), NULL);
                INSERT INTO sessions VALUES ('c', 'Archived', 'project', \(sql(iso(t(3)))), \(sql(iso(t(3)))));
                """)

            let snapshot = try AppDatabase.load(at: url)
            #expect(snapshot.sessions == [
                SessionMeta(id: "b", name: "", sessionType: "general_chat", isRunning: nil, updatedAt: t(2)),
                SessionMeta(id: "a", name: "Alpha", sessionType: "project", isRunning: nil, updatedAt: t(1)),
            ])
            #expect(snapshot.view == AppViewState())
        }
    }

    /// Standard SQLite builds remove the write-ahead log when the app closes the database, and a
    /// read-only connection can't recreate it.
    @Test func readsTheDatabaseWhileTheAppIsClosed() throws {
        try withTemporaryDirectory { directory in
            let folder = directory.appendingPathComponent("Copilot data", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("data.db")
            let db = try TestDatabase(at: url, journalMode: "WAL")
            try db.createAppSchema()
            try db.addSession(Self.chatId, title: "Saved", type: "general_chat")
            db.close()
            // macOS's SQLite keeps an empty log and the index instead; remove them as other builds do.
            for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: url.path + suffix) {
                try FileManager.default.removeItem(atPath: url.path + suffix)
            }

            #expect(try AppDatabase.load(at: url).sessions.map(\.id) == [Self.chatId])
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["data.db"])
        }
    }

    @Test func aMissingDatabaseIsAnErrorAndIsNotCreated() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("data.db")
            #expect(throws: AppDatabaseError.self) { try AppDatabase.load(at: url) }
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func readsDatesInAnyStoredForm() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("data.db")
            let db = try TestDatabase(at: url)
            defer { db.close() }
            // An untyped column keeps each value's own storage class.
            try db.exec("""
                CREATE TABLE dates (value);
                INSERT INTO dates VALUES ('2026-10-18T10:00:00.000Z'), (1792317600), (1792317600000), (1792317600.5),
                                         (NULL), ('not a date'), (x'00');
                """)
            let connection = try Connection(readOnly: url)
            let dates = try connection.rows("SELECT value FROM dates ORDER BY rowid") { $0.date(0) }
            #expect(dates == [t(0), t(0), t(0), t(0.5), nil, nil, nil])
        }
    }
}
