import Foundation

/// The coarse buckets the UI groups sessions into, in display order.
public enum DisplayPhase: String, Sendable, Codable, CaseIterable, Comparable {
    case needsYou, running, done, stopped, idle

    public var rank: Int {
        switch self {
        case .needsYou: return 0
        case .running: return 1
        case .done: return 2
        case .stopped: return 3
        case .idle: return 4
        }
    }

    public static func < (lhs: DisplayPhase, rhs: DisplayPhase) -> Bool { lhs.rank < rhs.rank }
}

/// Why a session is in its phase. Idle sessions keep the reason they ended with.
public enum StatusReason: String, Sendable, Codable {
    case question, planApproval, permission
    case working, starting
    case finished, interrupted, failed, unresponsive
    case idle

    public var headline: String {
        switch self {
        case .question: return "Waiting for your answer"
        case .planApproval: return "Plan ready for review"
        case .permission: return "Needs permission"
        case .working: return "Working"
        case .starting: return "Starting…"
        case .finished: return "Finished"
        case .interrupted: return "Interrupted"
        case .failed: return "Error"
        case .unresponsive: return "Stopped responding"
        case .idle: return "Idle"
        }
    }
}

public struct SessionSnapshot: Sendable, Equatable, Identifiable, Codable {
    public var id: String
    public var name: String
    public var projectName: String?
    public var branch: String?
    public var isChat: Bool
    public var mode: String?
    public var phase: DisplayPhase
    public var reason: StatusReason
    public var headline: String
    /// Question, plan summary, error message, or current step, depending on `reason`.
    public var detail: String?
    public var choices: [String]
    /// When the session entered its current state.
    public var since: Date?
    /// How full the session's context window is, when the app has measured it.
    public var contextUsage: ContextUsage? = nil

    public var displayName: String {
        if !name.isEmpty { return name }
        return isChat ? "Untitled chat" : "Untitled session"
    }

    /// Ended sessions keep their last state for context, even once they're no longer highlighted.
    public var isEnded: Bool {
        switch reason {
        case .finished, .interrupted, .failed, .unresponsive: return true
        default: return false
        }
    }
}

public struct ResolverOptions: Sendable, Equatable {
    /// How long finished/stopped sessions stay highlighted before turning idle.
    public var recentWindow: TimeInterval
    /// Silence after which a "running" log that the app no longer marks as running is considered dead.
    public var staleAfter: TimeInterval
    /// How long to trust the app's running flag before the CLI has written anything.
    public var startingGrace: TimeInterval

    public init(recentWindow: TimeInterval = 3_600, staleAfter: TimeInterval = 90, startingGrace: TimeInterval = 120) {
        self.recentWindow = recentWindow
        self.staleAfter = staleAfter
        self.startingGrace = startingGrace
    }
}

/// Combines the app's metadata with the event-log state into what the UI shows.
public enum StatusResolver {
    public static func snapshot(
        for record: SessionRecord, now: Date, options: ResolverOptions = ResolverOptions(),
        view: AppViewState = AppViewState(), acknowledgedAt: Date? = nil
    ) -> SessionSnapshot {
        let meta = record.meta
        var snapshot = SessionSnapshot(
            id: meta.id, name: PlainText.singleLine(meta.name), projectName: meta.projectName, branch: meta.branch,
            isChat: meta.isChat, mode: meta.mode, phase: .idle, reason: .idle,
            headline: StatusReason.idle.headline, detail: nil, choices: [], since: meta.updatedAt,
            contextUsage: meta.contextUsage
        )

        func set(_ phase: DisplayPhase, _ reason: StatusReason, since: Date?, detail: String? = nil, choices: [String] = []) {
            snapshot.phase = phase
            snapshot.reason = reason
            snapshot.headline = reason.headline
            snapshot.since = since
            snapshot.detail = detail.map(PlainText.fromMarkdown).flatMap { $0.isEmpty ? nil : $0 }
            snapshot.choices = choices
        }

        func ended(_ reason: StatusReason, at date: Date?, detail: String?) {
            let endedAt = date ?? meta.updatedAt
            let isRecent = endedAt.map { now.timeIntervalSince($0) <= options.recentWindow } ?? false
            let isSeen = hasBeenSeen(meta: meta, endedAt: endedAt, view: view, acknowledgedAt: acknowledgedAt)
            let phase: DisplayPhase = reason == .finished ? .done : .stopped
            set(isRecent && !isSeen ? phase : .idle, reason, since: endedAt, detail: detail)
        }

        guard let log = record.log, log.phase != .unknown else {
            if meta.isRunning == true {
                set(.running, .working, since: meta.updatedAt)
            } else if meta.wasInterrupted {
                ended(.interrupted, at: meta.updatedAt, detail: nil)
            }
            return snapshot
        }

        // The log says mid-turn, but the app says not running and the log has gone quiet:
        // the CLI died or was stopped without writing a final event. If the app's flag is
        // unknown, the log is trusted.
        if log.phase == .running, meta.isRunning == false,
           let lastEvent = log.lastEventAt, now.timeIntervalSince(lastEvent) > options.staleAfter {
            ended(meta.wasInterrupted ? .interrupted : .unresponsive, at: lastEvent, detail: nil)
            return snapshot
        }

        // The app already started a new turn but the CLI hasn't logged it yet.
        if meta.isRunning == true, log.phase != .running, let updatedAt = meta.updatedAt,
           now.timeIntervalSince(updatedAt) < options.startingGrace,
           updatedAt.timeIntervalSince(log.phaseSince ?? .distantPast) > 1 {
            set(.running, .starting, since: updatedAt)
            return snapshot
        }

        switch log.activity {
        case .needsPermission(let permission):
            set(.needsYou, .permission, since: permission.requestedAt, detail: permission.detail ?? permission.kind)
        case .needsAnswer(let tool):
            set(.needsYou, .question, since: tool.startedAt, detail: tool.question, choices: tool.choices)
        case .needsPlanApproval(let tool):
            set(.needsYou, .planApproval, since: tool.startedAt, detail: tool.planSummary)
        case .working(let since, let detail):
            set(.running, .working, since: since, detail: detail)
        case .finished(let at, let summary):
            ended(.finished, at: at, detail: summary ?? activityText(meta, kind: "agent_idle", near: at))
        case .interrupted(let at):
            ended(.interrupted, at: at, detail: nil)
        case .failed(let at, let message):
            ended(.failed, at: at, detail: message ?? activityText(meta, kind: "agent_error", near: at))
        case .unknown:
            break
        }
        return snapshot
    }

    /// Whether the user has already looked at a session since it ended: they opened it from
    /// Copilot Pulse, or the app's own unread marker for its workspace has since been cleared.
    static func hasBeenSeen(meta: SessionMeta, endedAt: Date?, view: AppViewState, acknowledgedAt: Date?) -> Bool {
        if let acknowledgedAt, acknowledgedAt >= (endedAt ?? .distantPast) { return true }
        if let workspaceId = meta.workspaceId, let unread = view.unreadWorkspaceIds,
           let updatedAt = view.unreadUpdatedAt, let endedAt, updatedAt >= endedAt {
            return !unread.contains(workspaceId)
        }
        return false
    }

    /// The app's own activity-feed preview, if it belongs to the same end of turn.
    static func activityText(_ meta: SessionMeta, kind: String, near date: Date?) -> String? {
        guard let activity = meta.lastActivity, activity.kind == kind, !activity.text.isEmpty else { return nil }
        if let date, let at = activity.at, at < date.addingTimeInterval(-30) { return nil }
        return activity.text
    }
}

/// Flattens the app's markdown snippets into one readable line.
public enum PlainText {
    public static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func fromMarkdown(_ markdown: String) -> String {
        var text = markdown
        // Links, including one cut off by the app's preview truncation.
        text = text.replacing(/!?\[([^\]]*)\]\([^)]*(\)|$)/) { String($0.output.1) }
        text = text.replacing(/(\*\*|__|`)/, with: "")
        text = text.replacing(/(?m)^\s{0,3}(#{1,6}\s+|>\s?|[-*+]\s+|\d+\.\s+)/, with: "")
        return singleLine(text)
    }
}

public enum SessionOrdering {
    /// Phase order; within "needs you" the longest-waiting first, otherwise most recent first.
    public static func sorted(_ snapshots: [SessionSnapshot]) -> [SessionSnapshot] {
        snapshots.sorted { lhs, rhs in
            if lhs.phase != rhs.phase { return lhs.phase < rhs.phase }
            let lhsDate = lhs.since ?? .distantPast
            let rhsDate = rhs.since ?? .distantPast
            if lhsDate != rhsDate {
                return lhs.phase == .needsYou ? lhsDate < rhsDate : lhsDate > rhsDate
            }
            let byName = lhs.displayName.localizedStandardCompare(rhs.displayName)
            if byName != .orderedSame { return byName == .orderedAscending }
            return lhs.id < rhs.id
        }
    }
}

public struct PhaseCounts: Sendable, Equatable, Codable {
    public var needsYou = 0
    public var running = 0
    public var done = 0
    public var stopped = 0
    public var idle = 0

    public init() {}

    public init(_ snapshots: [SessionSnapshot]) {
        for snapshot in snapshots { self[snapshot.phase] += 1 }
    }

    public subscript(phase: DisplayPhase) -> Int {
        get {
            switch phase {
            case .needsYou: return needsYou
            case .running: return running
            case .done: return done
            case .stopped: return stopped
            case .idle: return idle
            }
        }
        set {
            switch phase {
            case .needsYou: needsYou = newValue
            case .running: running = newValue
            case .done: done = newValue
            case .stopped: stopped = newValue
            case .idle: idle = newValue
            }
        }
    }

    /// Sessions worth showing (everything except idle).
    public var active: Int { needsYou + running + done + stopped }
}

public enum Elapsed {
    /// Compact relative time: `now`, `3m`, `1h 5m`, `2d`.
    public static func short(since date: Date?, now: Date) -> String {
        guard let date else { return "" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 {
            let remainder = minutes % 60
            return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
        }
        return "\(hours / 24)d"
    }
}
