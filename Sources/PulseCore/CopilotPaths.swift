import Foundation

/// Locations of the GitHub Copilot app's local state. Everything here is read-only for us.
public struct CopilotPaths: Sendable, Equatable {
    public var root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// `~/.copilot`, overridable with `COPILOT_PULSE_COPILOT_DIR` (used by tests and for debugging).
    public static func `default`(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CopilotPaths {
        if let override = environment["COPILOT_PULSE_COPILOT_DIR"], !override.isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            return CopilotPaths(root: URL(fileURLWithPath: expanded, isDirectory: true))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return CopilotPaths(root: home.appendingPathComponent(".copilot", isDirectory: true))
    }

    public var database: URL { root.appendingPathComponent("data.db") }
    /// SQLite's write-ahead log, where the app's commits land until a checkpoint.
    public var databaseWAL: URL { root.appendingPathComponent("data.db-wal") }
    public var sessionState: URL { root.appendingPathComponent("session-state", isDirectory: true) }

    public func sessionDirectory(_ id: String) -> URL {
        sessionState.appendingPathComponent(id, isDirectory: true)
    }

    public func eventsFile(_ id: String) -> URL {
        sessionDirectory(id).appendingPathComponent("events.jsonl")
    }
}
