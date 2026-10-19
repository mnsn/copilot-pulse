import Foundation
import Testing
@testable import PulseCore

@Suite struct EventLogReaderTests {
    @Test func loadsAndThenFollowsAppends() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("events.jsonl")
            try writeLog([
                Line.sessionStart(at: t(0)),
                Line.userMessage(at: t(1)),
                Line.assistantMessage(toolCalls: ["c1"], at: t(2)),
                Line.toolStart("bash", id: "c1", arguments: ["description": "Build"], at: t(3)),
            ], to: url)

            let reader = EventLogReader(url: url)
            #expect(reader.update())
            #expect(reader.isLoaded)
            #expect(reader.state.activity == .working(since: t(1), detail: "Build"))
            #expect(!reader.update())

            try appendLog([
                Line.toolComplete(id: "c1", at: t(4)), Line.assistantMessage(at: t(5)), Line.turnEnd(at: t(6)),
            ], to: url)
            #expect(reader.update())
            #expect(reader.state.activity == .finished(at: t(6), summary: nil))
            #expect(!reader.update())
        }
    }

    @Test func waitsForPartialLinesToComplete() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("events.jsonl")
            try writeLog([Line.userMessage(at: t(1))], to: url)
            let reader = EventLogReader(url: url)
            reader.update()

            let line = Line.permissionRequested(id: "r1", ["kind": "shell", "fullCommandText": "make"], at: t(2))
            let middle = line.index(line.startIndex, offsetBy: line.count / 2)
            try appendRaw(String(line[..<middle]), to: url)
            #expect(!reader.update())
            #expect(reader.state.pendingPermissions.isEmpty)

            try appendRaw(String(line[middle...]) + "\n", to: url)
            #expect(reader.update())
            #expect(reader.state.activity == .needsPermission(PendingPermission(
                requestId: "r1", kind: "shell", detail: "make", requestedAt: t(2)
            )))
        }
    }

    @Test func growsTheTailUntilItReachesTheStartOfTheTurn() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("events.jsonl")
            let lines = [
                Line.sessionStart(at: t(0)),
                Line.userMessage(at: t(1)),
                Line.assistantMessage(toolCalls: ["c1"], at: t(2)),
                Line.toolStart("bash", id: "c1", arguments: ["description": "Build"], at: t(3)),
            ] + (0..<20).map { Line.filler(bytes: 300, at: t(Double(4 + $0))) }
            try writeLog(lines, to: url)

            let reader = EventLogReader(url: url, tailChunkSizes: [512, 2_048, 1 << 20])
            reader.update()
            #expect(reader.state.activity == .working(since: t(1), detail: "Build"))
            #expect(reader.state.pendingTools.keys.sorted() == ["c1"])
            #expect(reader.state.lastEventAt == t(23))

            // Without room to grow, the same file shows no turn at all.
            let shortSighted = EventLogReader(url: url, tailChunkSizes: [512])
            shortSighted.update()
            #expect(shortSighted.state.phase == .unknown)
            #expect(shortSighted.state.lastEventAt == t(23))
        }
    }

    @Test func ignoresHistoryBeforeTheLatestTurn() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("events.jsonl")
            let lines = [
                Line.userMessage("Old request", at: t(0)),
                Line.toolStart("ask_user", id: "old", arguments: ["question": "Old question?"], at: t(1)),
            ] + (0..<10).map { Line.filler(bytes: 300, at: t(Double(10 + $0))) } + [
                Line.userMessage("New request", at: t(100)),
                Line.toolStart("bash", id: "new", at: t(101)),
            ]
            try writeLog(lines, to: url)

            let reader = EventLogReader(url: url, tailChunkSizes: [1_024, 1 << 20])
            reader.update()
            #expect(reader.state.pendingTools.keys.sorted() == ["new"])
            #expect(reader.state.phaseSince == t(100))
            // Replaying everything would have kept the old, never-answered question.
            #expect(logState(lines).pendingTools.keys.sorted() == ["new", "old"])
        }
    }

    @Test func reloadsAReplacedFile() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("events.jsonl")
            try writeLog([Line.userMessage(at: t(1)), Line.assistantMessage(at: t(2)), Line.turnEnd(at: t(3))], to: url)
            let reader = EventLogReader(url: url)
            reader.update()
            #expect(reader.state.phase == .finished)

            // Larger than the original, so only the file's identity reveals the swap.
            let replacement = directory.appendingPathComponent("replacement.jsonl")
            try writeLog([Line.userMessage(at: t(10)), Line.filler(bytes: 2_000, at: t(11))], to: replacement)
            try FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: replacement, to: url)

            #expect(reader.update())
            #expect(reader.state.activity == .working(since: t(10), detail: nil))
        }
    }

    @Test func reloadsATruncatedFile() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("events.jsonl")
            try writeLog([Line.userMessage(at: t(1)), Line.assistantMessage(at: t(2)), Line.turnEnd(at: t(3))], to: url)
            let reader = EventLogReader(url: url)
            reader.update()
            let before = try #require(FileInfo(path: url.path))

            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data((Line.userMessage(at: t(20)) + "\n").utf8))
            try handle.close()
            #expect(FileInfo(path: url.path)?.id == before.id)

            #expect(reader.update())
            #expect(reader.state.activity == .working(since: t(20), detail: nil))
        }
    }

    @Test func reloadsAFileRewrittenInPlace() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("events.jsonl")
            try writeLog([Line.userMessage(at: t(1)), Line.assistantMessage(at: t(2)), Line.turnEnd(at: t(3))], to: url)
            let reader = EventLogReader(url: url)
            reader.update()
            let before = try #require(FileInfo(path: url.path))

            // Same file, now larger than before, so only its changed contents reveal the rewrite.
            try rewrite(url, with: [Line.userMessage(at: t(20)), Line.filler(bytes: 2_000, at: t(21))])
            let after = try #require(FileInfo(path: url.path))
            #expect(after.id == before.id)
            #expect(after.size > before.size)

            #expect(reader.update())
            #expect(reader.state.activity == .working(since: t(20), detail: nil))
            #expect(reader.state.lastEventAt == t(21))
        }
    }

    @Test func reloadsAFileRewrittenToTheSameSize() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("events.jsonl")
            try writeLog([Line.userMessage("Fix A", at: t(1)), Line.toolStart("bash", id: "c1", at: t(2))], to: url)
            let reader = EventLogReader(url: url)
            reader.update()
            #expect(reader.state.pendingTools.keys.sorted() == ["c1"])
            let before = try #require(FileInfo(path: url.path))

            try rewrite(url, with: [Line.userMessage("Fix B", at: t(5)), Line.toolStart("bash", id: "c2", at: t(6))])
            // Make sure the rewrite is visible even on a clock too coarse to tell the writes apart.
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: 10)], ofItemAtPath: url.path
            )
            let after = try #require(FileInfo(path: url.path))
            try #require(after.id == before.id && after.size == before.size)

            #expect(reader.update())
            #expect(reader.state.pendingTools.keys.sorted() == ["c2"])
            #expect(reader.state.activity == .working(since: t(5), detail: nil))
            #expect(!reader.update())

            // A changed timestamp alone is not a rewrite.
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: 20)], ofItemAtPath: url.path
            )
            #expect(!reader.update())
            try appendLog([Line.toolComplete(id: "c2", at: t(7))], to: url)
            #expect(reader.update())
            #expect(reader.state.pendingTools.isEmpty)
            #expect(reader.state.phaseSince == t(5))
        }
    }

    @Test func aColdResumeEndsTheTurnWhetherAppendedOrInTheTail() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("events.jsonl")
            try writeLog([
                Line.userMessage(at: t(1)),
                Line.toolStart("ask_user", id: "q", arguments: ["question": "Ship it?"], at: t(2)),
            ], to: url)
            let reader = EventLogReader(url: url)
            reader.update()
            #expect(reader.state.pendingTools.keys.sorted() == ["q"])

            try appendLog([Line.resume(at: t(60))], to: url)
            #expect(reader.update())
            #expect(reader.state.activity == .interrupted(at: t(2)))

            // A fresh load starts at the last message, before the resume.
            let fresh = EventLogReader(url: url)
            fresh.update()
            #expect(fresh.state.activity == .interrupted(at: t(2)))
            #expect(fresh.state.pendingTools.isEmpty)
        }
    }

    /// Replaces the file's contents without replacing the file.
    private func rewrite(_ url: URL, with lines: [String]) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(lines.map { $0 + "\n" }.joined().utf8))
    }

    @Test func waitsForTheFileToAppear() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("session/events.jsonl")
            let reader = EventLogReader(url: url)
            #expect(!reader.update())
            #expect(!reader.isLoaded)

            try writeLog([], to: url)
            #expect(reader.update())
            #expect(reader.isLoaded)
            #expect(reader.state == SessionLogState())

            try appendLog([Line.userMessage(at: t(1))], to: url)
            #expect(reader.update())
            #expect(reader.state.phase == .running)
        }
    }

    @Test func rereadsTheTailAfterAnOversizedAppend() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("events.jsonl")
            try writeLog([Line.userMessage(at: t(1)), Line.toolStart("bash", id: "c1", at: t(2))], to: url)
            let reader = EventLogReader(url: url, tailChunkSizes: [600], maxIncrementalRead: 256)
            reader.update()
            #expect(reader.state.pendingTools.keys.sorted() == ["c1"])

            try appendLog([
                Line.filler(bytes: 2_000, at: t(3)),
                Line.toolStart("ask_user", id: "q", arguments: ["question": "Proceed?"], at: t(4)),
            ], to: url)
            #expect(reader.update())
            // Only the new tail was read, so the earlier call went with the history before it.
            #expect(reader.state.pendingTools.keys.sorted() == ["q"])
            #expect(reader.state.phaseSince == t(4))

            // Small appends are still read incrementally.
            try appendLog([Line.toolComplete(id: "q", at: t(5))], to: url)
            #expect(reader.update())
            #expect(reader.state.pendingTools.isEmpty)
            #expect(reader.state.phaseSince == t(4))
        }
    }

    @Test(arguments: [
        ("a\nb\nc", false, ["a", "b"], "c"),
        ("a\nb\n", false, ["a", "b"], ""),
        ("\n\na\n", false, ["a"], ""),
        ("x", false, [], "x"),
        ("", false, [], ""),
        ("partial\nb\nc", true, ["b"], "c"),
        ("\nb\n", true, ["b"], ""),
        ("no newline", true, [], ""),
    ] as [(String, Bool, [String], String)])
    func splitsLines(_ text: String, _ skipFirstPartial: Bool, _ expectedLines: [String], _ expectedRest: String) {
        var lines: [String] = []
        let rest = EventLogReader.forEachLine(in: Data(text.utf8), skipFirstPartial: skipFirstPartial) {
            lines.append(String(decoding: $0, as: UTF8.self))
        }
        #expect(lines == expectedLines)
        #expect(String(decoding: rest, as: UTF8.self) == expectedRest)
    }
}
