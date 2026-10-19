import Foundation
import Testing
@testable import PulseCore

@Suite struct EventLineParserTests {
    private func parse(_ line: String) -> LogEvent? {
        EventLineParser.parse(line)
    }

    @Test func userMessagesComeFromTheUserOnly() {
        #expect(parse(Line.userMessage("Hi", at: t(1))) == LogEvent(timestamp: t(1), kind: .userMessage))
        // Prompts the main agent sends to subagents carry a top-level agentId.
        let subagentPrompt = Line.userMessage("Explore the repo", at: t(2), agentId: "45e6ba2c-9409-4831-8e44-c91563cc057e")
        #expect(parse(subagentPrompt) == LogEvent(timestamp: t(2), kind: .other))
    }

    @Test func turnsAndReplies() {
        #expect(parse(Line.turnStart(at: t(1)))?.kind == .turnStart(isSubagent: false))
        #expect(parse(Line.turnStart(at: t(1), subagent: true))?.kind == .turnStart(isSubagent: true))
        #expect(parse(Line.turnEnd(at: t(1)))?.kind == .turnEnd(isSubagent: false))
        let subagentTurnEnd = Line.event("assistant.turn_end", data: ["turnId": "3"], at: t(1), agentId: "sub-agent")
        #expect(parse(subagentTurnEnd)?.kind == .turnEnd(isSubagent: true))

        #expect(parse(Line.assistantMessage(toolCalls: ["c1"], at: t(1)))?.kind
            == .assistantMessage(isSubagent: false, hasToolRequests: true))
        #expect(parse(Line.assistantMessage(at: t(1)))?.kind == .assistantMessage(isSubagent: false, hasToolRequests: false))
        #expect(parse(Line.event("assistant.message", data: ["content": "Done"], at: t(1)))?.kind
            == .assistantMessage(isSubagent: false, hasToolRequests: false))
        #expect(parse(Line.assistantMessage(toolCalls: ["c2"], at: t(1), subagent: true))?.kind
            == .assistantMessage(isSubagent: true, hasToolRequests: true))
    }

    @Test func toolStarts() {
        let bash = Line.toolStart(
            "bash", id: "c1", arguments: ["command": "swift test", "description": " Run tests "], title: "Bash", at: t(1)
        )
        #expect(parse(bash) == LogEvent(
            timestamp: t(1), kind: .toolStart(.init(callId: "c1", name: "bash", title: "Bash", description: "Run tests"))
        ))

        let question = Line.toolStart(
            "ask_user", id: "q", arguments: ["question": "Which DB?", "choices": ["Postgres", " ", "SQLite"]], at: t(2)
        )
        #expect(parse(question)?.kind
            == .toolStart(.init(callId: "q", name: "ask_user", question: "Which DB?", choices: ["Postgres", "SQLite"])))

        let plan = Line.toolStart("exit_plan_mode", id: "p", arguments: ["summary": "1. Add tests"], at: t(3))
        #expect(parse(plan)?.kind == .toolStart(.init(callId: "p", name: "exit_plan_mode", planSummary: "1. Add tests")))

        // Only ask_user's arguments are a question for the user.
        let notAQuestion = Line.toolStart("bash", id: "c2", arguments: ["question": "rhetorical"], at: t(4))
        #expect(parse(notAQuestion)?.kind == .toolStart(.init(callId: "c2", name: "bash")))

        #expect(parse(Line.toolStart("view", id: "c3", at: t(5), subagent: true))?.kind
            == .toolStart(.init(callId: "c3", name: "view", isSubagent: true)))
        #expect(parse(Line.event("tool.execution_start", data: ["toolName": "bash"], at: t(6)))?.kind == .other)
    }

    @Test func toolCompletionsUseTheEventsOwnTimestamp() {
        #expect(parse(Line.toolComplete(id: "c1", at: t(7))) == LogEvent(timestamp: t(7), kind: .toolComplete(callId: "c1")))
        // Another key order takes the full-decode path.
        let reordered = Line.event("tool.execution_complete", data: ["success": true, "toolCallId": "c2"], at: t(8))
        #expect(parse(reordered) == LogEvent(timestamp: t(8), kind: .toolComplete(callId: "c2")))
    }

    @Test func permissionRequestsDescribeWhatIsAsked() {
        let fromExtension = Line.permissionRequested(
            id: "r1",
            ["kind": "extension-permission-access", "extensionName": "project:scs-chat", "capabilities": ["register hooks"]],
            at: t(1)
        )
        #expect(parse(fromExtension)?.kind == .permissionRequested(.init(
            requestId: "r1", kind: "extension-permission-access", detail: "project:scs-chat extension wants access"
        )))

        let shell = Line.permissionRequested(
            id: "r2", ["kind": "shell", "fullCommandText": "rm -rf build", "intention": "Clean the build folder"], at: t(2)
        )
        #expect(parse(shell)?.kind
            == .permissionRequested(.init(requestId: "r2", kind: "shell", detail: "Clean the build folder")))

        let commandOnly = Line.permissionRequested(id: "r3", ["kind": "shell", "fullCommandText": "rm -rf build"], at: t(3))
        #expect(parse(commandOnly)?.kind == .permissionRequested(.init(requestId: "r3", kind: "shell", detail: "rm -rf build")))

        let bare = Line.permissionRequested(id: "r4", ["kind": "url"], at: t(4))
        #expect(parse(bare)?.kind == .permissionRequested(.init(requestId: "r4", kind: "url")))

        #expect(parse(Line.permissionCompleted(id: "r1", at: t(5)))?.kind == .permissionCompleted(requestId: "r1"))
    }

    @Test func onlyAgentStopHooksMatter() {
        #expect(parse(Line.hook("agentStop", at: t(1))) == LogEvent(timestamp: t(1), kind: .agentStop(isSubagent: false)))
        #expect(parse(Line.hook("agentStop", at: t(2), agentId: "sub-agent"))?.kind == .agentStop(isSubagent: true))
        #expect(parse(Line.hook("preToolUse", at: t(3))) == LogEvent(timestamp: t(3), kind: .other))
    }

    @Test func sessionLifecycle() {
        #expect(parse(Line.abort(at: t(1)))?.kind == .abort(reason: "user_initiated"))
        #expect(parse(Line.abort("subagent_cancelled", at: t(1)))?.kind == .abort(reason: "subagent_cancelled"))
        #expect(parse(Line.sessionError("Rate limited", at: t(2)))?.kind
            == .sessionError(errorType: "query", message: "Rate limited"))
        #expect(parse(Line.taskComplete("Shipped", at: t(3)))?.kind == .taskComplete(summary: "Shipped", success: true))
        #expect(parse(Line.shutdown(at: t(4))) == LogEvent(timestamp: t(4), kind: .sessionShutdown))
        #expect(parse(Line.sessionStart(at: t(5)))?.kind == .sessionStart)
        #expect(parse(Line.event("session.resume", data: ["resumeTime": iso(t(6))], at: t(6)))?.kind == .sessionResume)
    }

    @Test func irrelevantAndMalformedLines() {
        #expect(parse(Line.filler(bytes: 4_000, at: t(1))) == LogEvent(timestamp: t(1), kind: .other))
        #expect(parse(Line.event("system.message", data: ["content": "You are…"], at: t(2)))?.kind == .other)
        for garbage in ["", " ", "not json", "{}", "[1,2]", #"{"type":42}"#] {
            #expect(parse(garbage) == nil, "\(garbage)")
        }
    }

    @Test func toleratesWhitespaceAndOtherKeyOrders() {
        #expect(parse("  " + Line.shutdown(at: t(1)) + "\r\n") == LogEvent(timestamp: t(1), kind: .sessionShutdown))

        let reordered = #"{"timestamp":"\#(iso(t(2)))","data":{"reason":"user_initiated"},"type":"abort"}"#
        #expect(parse(reordered) == LogEvent(timestamp: t(2), kind: .abort(reason: "user_initiated")))

        let escapedType = #"{"type":"user\u002emessage","data":{"content":"hi"},"id":"x","timestamp":"\#(iso(t(3)))","parentId":null}"#
        #expect(parse(escapedType) == LogEvent(timestamp: t(3), kind: .userMessage))
    }
}
