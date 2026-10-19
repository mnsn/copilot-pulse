import Foundation
import Synchronization
import Testing
@testable import PulseCore

private final class ChangeCounter: Sendable {
    private let value = Mutex(0)

    func increment() {
        value.withLock { $0 += 1 }
    }

    var count: Int {
        value.withLock { $0 }
    }

    func wait(forMoreThan previous: Int, timeout: Duration = .seconds(5)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if count > previous { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TestError("No change reported within \(timeout)")
    }
}

@Suite struct FileWriteWatcherTests {
    private let queue = DispatchQueue(label: "FileWriteWatcherTests")

    private func write(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    @Test func reportsWritesToAFileThatStaysOpen() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("data.db-wal")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let counter = ChangeCounter()
        let watcher = FileWriteWatcher(path: url.path, queue: queue) { counter.increment() }
        defer { queue.sync { watcher.cancel() } }
        #expect(queue.sync { watcher.rearm() })

        // Like SQLite's connection to its log: written to, never closed (which is all FSEvents reports).
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data("frame 1".utf8))
        try await counter.wait(forMoreThan: 0)
        let afterFirstWrite = counter.count
        try handle.write(contentsOf: Data("frame 2".utf8))
        try await counter.wait(forMoreThan: afterFirstWrite)
    }

    @Test func waitsForAMissingFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("data.db-wal")
        let watcher = FileWriteWatcher(path: url.path, queue: queue) {}
        #expect(!queue.sync { watcher.rearm() })
        #expect(!queue.sync { watcher.isArmed })

        FileManager.default.createFile(atPath: url.path, contents: nil)
        #expect(queue.sync { watcher.rearm() })
        // Rearming the same file keeps the existing watch.
        #expect(queue.sync { watcher.rearm() })
        queue.sync { watcher.cancel() }
        #expect(!queue.sync { watcher.isArmed })
    }

    @Test func letsGoOfADeletedFileAndPicksUpItsSuccessor() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("data.db-wal")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let counter = ChangeCounter()
        let watcher = FileWriteWatcher(path: url.path, queue: queue) { counter.increment() }
        defer { queue.sync { watcher.cancel() } }
        #expect(queue.sync { watcher.rearm() })

        try FileManager.default.removeItem(at: url)
        try await counter.wait(forMoreThan: 0)
        #expect(!queue.sync { watcher.isArmed })

        // The caller rearms once the path exists again (the engine does so on FSEvents' "created").
        FileManager.default.createFile(atPath: url.path, contents: nil)
        #expect(queue.sync { watcher.rearm() })
        let beforeWrite = counter.count
        try write("frame", to: url)
        try await counter.wait(forMoreThan: beforeWrite)
    }

    @Test func movesToAFileSwappedIntoPlace() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("data.db-wal")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let counter = ChangeCounter()
        let watcher = FileWriteWatcher(path: url.path, queue: queue) { counter.increment() }
        defer { queue.sync { watcher.cancel() } }
        #expect(queue.sync { watcher.rearm() })

        let replacement = directory.appendingPathComponent("replacement")
        FileManager.default.createFile(atPath: replacement.path, contents: nil)
        #expect(rename(replacement.path, url.path) == 0)
        try await counter.wait(forMoreThan: 0)
        #expect(queue.sync { watcher.isArmed })

        let beforeWrite = counter.count
        try write("frame", to: url)
        try await counter.wait(forMoreThan: beforeWrite)
    }
}
