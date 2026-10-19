import Foundation

/// The subset of a Copilot session `events.jsonl` line that matters for status tracking.
public struct LogEvent: Sendable, Equatable {
    public var timestamp: Date?
    public var kind: Kind

    public init(timestamp: Date?, kind: Kind) {
        self.timestamp = timestamp
        self.kind = kind
    }

    public enum Kind: Sendable, Equatable {
        case userMessage
        case turnStart(isSubagent: Bool)
        case turnEnd(isSubagent: Bool)
        case assistantMessage(isSubagent: Bool, hasToolRequests: Bool)
        case toolStart(ToolStart)
        case toolComplete(callId: String)
        case permissionRequested(PermissionRequest)
        case permissionCompleted(requestId: String)
        /// `hook.start` with `hookType == "agentStop"`: the agent finished its interaction.
        case agentStop(isSubagent: Bool)
        case abort(reason: String?)
        case sessionError(errorType: String?, message: String?)
        case sessionStart
        /// A resume that abandoned what the previous CLI process left pending. A resume that keeps
        /// that work waiting, or joins a turn another client is running, is `.other`.
        case sessionResume
        case sessionShutdown
        case taskComplete(summary: String?, success: Bool?)
        case other
    }

    public struct ToolStart: Sendable, Equatable {
        public var callId: String
        public var name: String
        public var isSubagent: Bool
        public var title: String?
        /// Free-text description argument some tools take (e.g. `bash`).
        public var description: String?
        /// `ask_user` question and choices.
        public var question: String?
        public var choices: [String]
        /// `exit_plan_mode` summary.
        public var planSummary: String?

        public init(
            callId: String, name: String, isSubagent: Bool = false, title: String? = nil,
            description: String? = nil, question: String? = nil, choices: [String] = [],
            planSummary: String? = nil
        ) {
            self.callId = callId
            self.name = name
            self.isSubagent = isSubagent
            self.title = title
            self.description = description
            self.question = question
            self.choices = choices
            self.planSummary = planSummary
        }
    }

    public struct PermissionRequest: Sendable, Equatable {
        public var requestId: String
        public var kind: String?
        public var detail: String?

        public init(requestId: String, kind: String? = nil, detail: String? = nil) {
            self.requestId = requestId
            self.kind = kind
            self.detail = detail
        }
    }
}

public extension LogEvent.Kind {
    /// Events from which a session's state can be rebuilt without older history.
    var isAnchor: Bool {
        switch self {
        case .userMessage, .sessionStart: return true
        default: return false
        }
    }
}
