import Foundation
import PulseCore

/// Command-line modes, mainly for debugging what the widget would show.
enum CLI {
    static let usage = """
        Copilot Pulse: live status of your GitHub Copilot app sessions.

        Usage: CopilotPulse [option]
          (no option)   Run the menu-bar app and desktop widget
          --dump        Print every visible session and its status
          --json        Print the same as JSON
          --watch       Print status changes live as they happen (Ctrl-C to stop)
          --help        Show this help

        Set COPILOT_PULSE_COPILOT_DIR to read a different Copilot data directory.
        """

    /// Returns an exit code for CLI modes, or nil to launch the app.
    static func run(_ arguments: [String]) -> Int32? {
        if arguments.contains("--help") || arguments.contains("-h") {
            print(usage)
            return 0
        }
        if arguments.contains("--json") {
            return printJSON()
        }
        if arguments.contains("--dump") {
            let state = SessionEngine.loadOnce()
            printTable(resolve(state, now: Date()), problem: state.problem)
            return 0
        }
        if arguments.contains("--watch") {
            watch()
        }
        return nil
    }

    static func resolve(_ state: EngineSnapshot, now: Date) -> [SessionSnapshot] {
        SessionOrdering.sorted(state.records.map {
            StatusResolver.snapshot(for: $0, now: now, view: state.view)
        })
    }

    private static func printJSON() -> Int32 {
        let state = SessionEngine.loadOnce()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        struct Output: Encodable {
            var sessions: [SessionSnapshot]
            var counts: PhaseCounts
            var problem: String?
        }
        let sessions = resolve(state, now: Date())
        guard let data = try? encoder.encode(Output(sessions: sessions, counts: PhaseCounts(sessions), problem: state.problem)) else {
            return 1
        }
        FileHandle.standardOutput.write(data)
        print()
        return 0
    }

    private static func printTable(_ sessions: [SessionSnapshot], problem: String?) {
        if let problem { print("! \(problem)") }
        let now = Date()
        let counts = PhaseCounts(sessions)
        print("needs you \(counts.needsYou) · running \(counts.running) · done \(counts.done) · stopped \(counts.stopped) · idle \(counts.idle)")
        print(row("PHASE", "STATUS", "SINCE", "SESSION", "DETAIL"))
        for session in sessions {
            let name = session.projectName.map { "\(session.displayName) [\($0)]" } ?? session.displayName
            print(row(
                session.phase.rawValue, session.headline, Elapsed.short(since: session.since, now: now),
                name, session.detail ?? ""
            ))
        }
    }

    private static func row(_ phase: String, _ status: String, _ since: String, _ name: String, _ detail: String) -> String {
        [pad(phase, 9), pad(status, 24), pad(since, 7), pad(name, 46), String(detail.prefix(70))].joined(separator: " ")
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        let clipped = text.count > width ? String(text.prefix(width - 1)) + "…" : text
        return clipped.padding(toLength: width, withPad: " ", startingAt: 0)
    }

    private static func watch() -> Never {
        let printer = WatchPrinter()
        let engine = SessionEngine { state in printer.print(state) }
        engine.start()
        setvbuf(stdout, nil, _IOLBF, 0)
        print("Watching \(engine.paths.root.path) — Ctrl-C to stop")
        dispatchMain()
    }
}

/// Prints only the sessions whose displayed status changed. Called on the engine's queue.
private final class WatchPrinter: @unchecked Sendable {
    private var previous: [String: SessionSnapshot] = [:]
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    func print(_ state: EngineSnapshot) {
        let now = Date()
        for session in CLI.resolve(state, now: now) {
            let old = previous[session.id]
            previous[session.id] = session
            guard old == nil || old?.phase != session.phase || old?.headline != session.headline
                || old?.detail != session.detail
            else { continue }
            if old == nil, session.phase == .idle { continue }
            let detail = session.detail.map { " — \($0.prefix(90))" } ?? ""
            Swift.print("\(formatter.string(from: now))  \(session.phase.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) \(session.headline): \(session.displayName)\(detail)")
        }
    }
}
