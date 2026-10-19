import Foundation
import Testing
@testable import PulseCore

@Suite struct SessionEngineTests {
    @Test func loadsSessionsWithTheirLogs() throws {
        try withTemporaryDirectory { root in
            let paths = CopilotPaths(root: root)
            let db = try TestDatabase(at: paths.database)
            defer { db.close() }
            try db.createAppSchema()
            try db.addProject("p1", name: "acme-web")
            for id in ["asking", "finished", "fresh"] {
                try db.addSession(id, title: id.capitalized, running: id == "asking", updatedAt: t(1))
                try db.addWorkspace("w-\(id)", session: id, name: id.capitalized)
            }
            try writeLog([
                Line.userMessage(at: t(1)),
                Line.toolStart("ask_user", id: "q", arguments: ["question": "Ship it?"], at: t(2)),
            ], to: paths.eventsFile("asking"))
            try writeLog(
                [Line.userMessage(at: t(1)), Line.assistantMessage(at: t(2)), Line.turnEnd(at: t(3))],
                to: paths.eventsFile("finished")
            )
            // A log the app doesn't list (e.g. a CLI-only session) is ignored.
            try writeLog([Line.userMessage(at: t(1))], to: paths.eventsFile("orphan"))

            let snapshot = SessionEngine.loadOnce(paths: paths)
            #expect(snapshot.problem == nil)
            let records = Dictionary(uniqueKeysWithValues: snapshot.records.map { ($0.id, $0) })
            #expect(records.keys.sorted() == ["asking", "finished", "fresh"])
            #expect(try #require(records["fresh"]).log == nil)

            let phases = records.mapValues { StatusResolver.snapshot(for: $0, now: t(60), view: snapshot.view).phase }
            #expect(phases == ["asking": .needsYou, "finished": .done, "fresh": .idle])
        }
    }

    @Test func reportsMissingCopilotData() throws {
        try withTemporaryDirectory { directory in
            let paths = CopilotPaths(root: directory.appendingPathComponent("missing", isDirectory: true))
            let snapshot = SessionEngine.loadOnce(paths: paths)
            #expect(snapshot.records.isEmpty)
            #expect(snapshot.problem == "No Copilot data found at \(paths.root.path)")
        }
    }

    @Test func fallsBackToSessionFoldersWithoutADatabase() throws {
        try withTemporaryDirectory { root in
            let paths = CopilotPaths(root: root)
            try writeLog([Line.userMessage(at: t(1))], to: paths.eventsFile("recent"))
            try "id: recent\nname: \"Fix the build\"\n".write(
                to: paths.sessionDirectory("recent").appendingPathComponent("workspace.yaml"),
                atomically: true, encoding: .utf8
            )
            try writeLog([Line.userMessage(at: t(1))], to: paths.eventsFile("unnamed-session"))
            try writeLog([Line.userMessage(at: t(1))], to: paths.eventsFile("old"))
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-3 * 86_400)], ofItemAtPath: paths.eventsFile("old").path
            )
            try FileManager.default.createDirectory(at: paths.sessionDirectory("empty"), withIntermediateDirectories: true)

            let snapshot = SessionEngine.loadOnce(paths: paths)
            let names = Dictionary(uniqueKeysWithValues: snapshot.records.map { ($0.id, $0.meta.name) })
            #expect(names == ["recent": "Fix the build", "unnamed-session": "Session unnamed-"])
            #expect(snapshot.records.allSatisfy { $0.log?.phase == .running && $0.meta.isRunning == nil })
            #expect(snapshot.problem?.contains("Could not open Copilot database") == true)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func keepsTheLastListWhileTheDatabaseCannotBeRead() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = CopilotPaths(root: root)
        let db = try TestDatabase(at: paths.database)
        defer { db.close() }
        try db.createAppSchema()
        try db.addProject("p1", name: "Pulse")
        try db.addSession("live", title: "Live", running: true, updatedAt: Date())
        try db.addWorkspace("w-live", session: "live", name: "Live session")

        let collector = SnapshotCollector()
        let engine = SessionEngine(paths: paths, metadataThrottle: 0.05, safetyInterval: 3_600) { collector.add($0) }
        engine.start()
        defer { engine.stop() }
        try await collector.wait("the initial load") { $0.records.first?.meta.isRunning == true }

        // Neither the main nor the fallback query can read this.
        try db.exec("ALTER TABLE sessions RENAME TO renamed_sessions;")
        engine.refresh()
        let stale = try await collector.wait("the failed reload") { $0.problem != nil }
        #expect(stale.records.map(\.meta.name) == ["Live session"])
        // The last known running flag may be out of date by now.
        #expect(stale.records.first?.meta.isRunning == nil)
        #expect(stale.problem?.hasSuffix("The list may be out of date.") == true)

        try db.exec("ALTER TABLE renamed_sessions RENAME TO sessions;")
        engine.refresh()
        let recovered = try await collector.wait("the recovered reload") { $0.problem == nil }
        #expect(recovered.records.first?.meta.isRunning == true)
    }

    /// The point of the whole design: changes are pushed by FSEvents, nothing polls.
    @Test(.timeLimit(.minutes(1)))
    func pushesLogAndDatabaseChangesWithoutPolling() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = CopilotPaths(root: root)
        let db = try TestDatabase(at: paths.database, journalMode: "WAL")
        defer { db.close() }
        try db.createAppSchema()
        try db.addProject("p1", name: "Pulse")
        try db.addSession("live", title: "Live", running: true, updatedAt: Date())
        try db.addWorkspace("w-live", session: "live", name: "Live session")
        let log = paths.eventsFile("live")
        try writeLog([
            Line.userMessage(at: Date()),
            Line.assistantMessage(toolCalls: ["c1"], at: Date()),
            Line.toolStart("bash", id: "c1", arguments: ["description": "Build"], at: Date()),
        ], to: log)

        let collector = SnapshotCollector()
        let engine = SessionEngine(paths: paths, metadataThrottle: 0.05, safetyInterval: 3_600) { collector.add($0) }
        engine.start()
        defer { engine.stop() }

        try await collector.wait("the initial load") { $0.records.first?.log?.phase == .running }

        try appendLog([
            Line.toolComplete(id: "c1", at: Date()), Line.assistantMessage(at: Date()), Line.turnEnd(at: Date()),
        ], to: log)
        try await collector.wait("the appended log lines") { $0.records.first?.log?.phase == .finished }

        // The app keeps its database open, so this commit only reaches the write-ahead log.
        try db.exec("UPDATE sessions SET is_running = 0 WHERE id = 'live';")
        try await collector.wait("the database update") { $0.records.first?.meta.isRunning == false }

        // The app restarting: closing its connection removes the log, and the next one starts a new log.
        db.close()
        let reopened = try TestDatabase(at: paths.database, journalMode: "WAL")
        defer { reopened.close() }
        try reopened.exec("UPDATE workspaces SET name = 'Renamed' WHERE id = 'w-live';")
        try await collector.wait("the reopened database") { $0.records.first?.meta.name == "Renamed" }
        try reopened.exec("UPDATE workspaces SET branch = 'next' WHERE id = 'w-live';")
        try await collector.wait("a write to the new log") { $0.records.first?.meta.branch == "next" }

        // With nothing changing, nothing is published.
        let published = collector.count
        try await Task.sleep(for: .seconds(1))
        #expect(collector.count == published)
    }

    @Test func locatesCopilotData() {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".copilot").path
        #expect(CopilotPaths.default(environment: [:]).root.path == home)
        #expect(CopilotPaths.default(environment: ["COPILOT_PULSE_COPILOT_DIR": ""]).root.path == home)
        #expect(CopilotPaths.default(environment: ["COPILOT_PULSE_COPILOT_DIR": "~/elsewhere"]).root.path
            == NSString(string: "~/elsewhere").expandingTildeInPath)

        let paths = CopilotPaths(root: URL(fileURLWithPath: "/nonexistent/copilot", isDirectory: true))
        #expect(paths.root.path == "/nonexistent/copilot")
        #expect(paths.database.path == "/nonexistent/copilot/data.db")
        #expect(paths.eventsFile("abc").path == "/nonexistent/copilot/session-state/abc/events.jsonl")
    }

    @Test(arguments: [
        ("name: Fix the build", "Fix the build"),
        ("id: abc\nname:   spaced out  \nbranch: main", "spaced out"),
        ("name: \"Double quoted\"", "Double quoted"),
        ("name: 'Single quoted'", "Single quoted"),
        ("name: \"unbalanced", "\"unbalanced"),
        ("name: \"\"", nil),
        ("name:", nil),
        ("  name: nested", nil),
        ("branch: main", nil),
    ] as [(String, String?)])
    func readsWorkspaceNames(_ yaml: String, _ expected: String?) throws {
        try withTemporaryDirectory { directory in
            try yaml.write(to: directory.appendingPathComponent("workspace.yaml"), atomically: true, encoding: .utf8)
            #expect(SessionStateScanner.workspaceName(in: directory) == expected)
        }
    }

    @Test func noWorkspaceFileMeansNoName() throws {
        try withTemporaryDirectory { directory in
            #expect(SessionStateScanner.workspaceName(in: directory) == nil)
        }
    }
}
