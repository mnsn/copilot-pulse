import Foundation

public enum LogPhase: String, Sendable, Codable, Equatable {
    case unknown, running, finished, interrupted, failed
}

public struct PendingTool: Sendable, Equatable {
    public var callId: String
    public var name: String
    public var startedAt: Date?
    public var question: String?
    public var choices: [String]
    public var planSummary: String?
}

public struct PendingPermission: Sendable, Equatable {
    public var requestId: String
    public var kind: String?
    public var detail: String?
    public var requestedAt: Date?
}

/// What the main agent of a session is doing, derived purely from its event log.
public enum LogActivity: Sendable, Equatable {
    case unknown
    case working(since: Date?, detail: String?)
    case needsPermission(PendingPermission)
    case needsAnswer(PendingTool)
    case needsPlanApproval(PendingTool)
    case finished(at: Date?, summary: String?)
    case interrupted(at: Date?)
    case failed(at: Date?, message: String?)
}

/// Reducer over a session's events. Subagent events (`parentToolCallId`) never change the
/// main agent's phase; they only matter through the main agent's own tool calls.
public struct SessionLogState: Sendable, Equatable {
    public private(set) var phase: LogPhase = .unknown
    public private(set) var phaseSince: Date?
    public private(set) var lastEventAt: Date?
    public private(set) var errorMessage: String?
    public private(set) var summary: String?
    /// Short description of the latest main-agent tool call, e.g. a bash command's description.
    public private(set) var currentStep: String?
    public private(set) var pendingTools: [String: PendingTool] = [:]
    public private(set) var pendingPermissions: [String: PendingPermission] = [:]
    public private(set) var lastMainMessageHadTools = false

    private static let interactionTools: Set<String> = ["ask_user", "exit_plan_mode", "report_intent", "task_complete"]

    public init() {}

    public mutating func apply<S: Sequence>(_ events: S) where S.Element == LogEvent {
        for event in events { apply(event) }
    }

    public mutating func apply(_ event: LogEvent) {
        let previousEventAt = lastEventAt
        if let timestamp = event.timestamp, timestamp > (lastEventAt ?? .distantPast) {
            lastEventAt = timestamp
        }
        let at = event.timestamp ?? lastEventAt

        switch event.kind {
        case .userMessage:
            // Anything still pending from a previous, already-ended interaction is stale.
            if phase != .running {
                clearPending()
                lastMainMessageHadTools = false
                currentStep = nil
            }
            errorMessage = nil
            summary = nil
            enter(.running, at: at)

        case .turnStart(let isSubagent):
            guard !isSubagent else { return }
            enter(.running, at: at)

        case .assistantMessage(let isSubagent, let hasToolRequests):
            guard !isSubagent else { return }
            lastMainMessageHadTools = hasToolRequests
            if phase == .unknown { enter(.running, at: at) }

        case .toolStart(let tool):
            guard !tool.isSubagent else { return }
            pendingTools[tool.callId] = PendingTool(
                callId: tool.callId, name: tool.name, startedAt: at,
                question: tool.question, choices: tool.choices, planSummary: tool.planSummary
            )
            if !Self.interactionTools.contains(tool.name) {
                currentStep = tool.description ?? tool.title
            }
            if phase == .unknown { enter(.running, at: at) }

        case .toolComplete(let callId):
            pendingTools.removeValue(forKey: callId)

        case .permissionRequested(let request):
            pendingPermissions[request.requestId] = PendingPermission(
                requestId: request.requestId, kind: request.kind, detail: request.detail, requestedAt: at
            )
            if phase == .unknown { enter(.running, at: at) }

        case .permissionCompleted(let requestId):
            pendingPermissions.removeValue(forKey: requestId)

        case .turnEnd(let isSubagent):
            // turn_end also separates model turns mid-run (immediately followed by turn_start),
            // so it only means "done" when the last reply asked for no tools and nothing is pending.
            guard !isSubagent else { return }
            if phase == .running, !lastMainMessageHadTools, pendingTools.isEmpty, pendingPermissions.isEmpty {
                finish(at: at)
            }

        case .agentStop(let isSubagent):
            guard !isSubagent else { return }
            if phase == .running || phase == .unknown { finish(at: at) }

        case .abort(let reason):
            guard reason != "subagent_cancelled" else { return }
            clearPending()
            currentStep = nil
            enter(.interrupted, at: at)

        case .sessionError(_, let message):
            clearPending()
            currentStep = nil
            errorMessage = message
            enter(.failed, at: at)

        case .sessionShutdown:
            clearPending()
            if phase == .running {
                currentStep = nil
                enter(.interrupted, at: at)
            }

        case .taskComplete(let summary, _):
            self.summary = summary
            if phase == .running || phase == .unknown { finish(at: at) }

        case .sessionResume:
            // A new CLI process dropped what the previous one left pending. Without a shutdown
            // event, that process stopped mid-turn, the last time it wrote something.
            clearPending()
            lastMainMessageHadTools = false
            currentStep = nil
            if phase == .running {
                enter(.interrupted, at: previousEventAt ?? at)
            }

        case .sessionStart, .other:
            break
        }
    }

    public var activity: LogActivity {
        if phase == .running || phase == .unknown {
            if let permission = pendingPermissions.values.min(by: { Self.earlier($0.requestedAt, $1.requestedAt) }) {
                return .needsPermission(permission)
            }
            let tools = pendingTools.values.sorted { Self.earlier($0.startedAt, $1.startedAt) }
            if let question = tools.first(where: { $0.name == "ask_user" }) {
                return .needsAnswer(question)
            }
            if let plan = tools.first(where: { $0.name == "exit_plan_mode" }) {
                return .needsPlanApproval(plan)
            }
        }
        switch phase {
        case .unknown: return .unknown
        case .running: return .working(since: phaseSince, detail: currentStep)
        case .finished: return .finished(at: phaseSince, summary: summary)
        case .interrupted: return .interrupted(at: phaseSince)
        case .failed: return .failed(at: phaseSince, message: errorMessage)
        }
    }

    private mutating func enter(_ newPhase: LogPhase, at date: Date?) {
        if phase != newPhase {
            phase = newPhase
            phaseSince = date
        } else if phaseSince == nil {
            phaseSince = date
        }
    }

    private mutating func finish(at date: Date?) {
        clearPending()
        currentStep = nil
        enter(.finished, at: date)
    }

    private mutating func clearPending() {
        pendingTools.removeAll()
        pendingPermissions.removeAll()
    }

    private static func earlier(_ lhs: Date?, _ rhs: Date?) -> Bool {
        (lhs ?? .distantPast) < (rhs ?? .distantPast)
    }
}
