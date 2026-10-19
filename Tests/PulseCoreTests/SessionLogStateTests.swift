import Foundation
import Testing
@testable import PulseCore

@Suite struct SessionLogStateTests {
    @Test func startsUnknown() {
        let state = SessionLogState()
        #expect(state.phase == .unknown)
        #expect(state.phaseSince == nil)
        #expect(state.lastEventAt == nil)
        #expect(state.activity == .unknown)
    }

    @Test func turnEndBetweenToolCallsDoesNotFinish() {
        var lines = [
            Line.sessionStart(at: t(0)),
            Line.userMessage(at: t(1)),
            Line.turnStart(at: t(2)),
            Line.assistantMessage(toolCalls: ["c1"], at: t(3)),
            Line.toolStart("bash", id: "c1", arguments: ["description": "Run tests"], at: t(4)),
            Line.toolComplete(id: "c1", at: t(5)),
            Line.turnEnd(at: t(6)),
        ]
        let midRun = logState(lines)
        #expect(midRun.phase == .running)
        #expect(midRun.activity == .working(since: t(1), detail: "Run tests"))

        lines += [Line.turnStart(at: t(7)), Line.assistantMessage(at: t(8)), Line.turnEnd(at: t(9))]
        let done = logState(lines)
        #expect(done.activity == .finished(at: t(9), summary: nil))
        #expect(done.currentStep == nil)
        #expect(done.lastEventAt == t(9))
    }

    @Test func pendingWorkBlocksFinishing() {
        var lines = [
            Line.userMessage(at: t(1)),
            Line.permissionRequested(id: "r1", ["kind": "shell", "fullCommandText": "make"], at: t(2)),
            Line.assistantMessage(at: t(3)),
            Line.turnEnd(at: t(4)),
        ]
        #expect(logState(lines).phase == .running)

        lines += [Line.permissionCompleted(id: "r1", at: t(5)), Line.turnEnd(at: t(6))]
        #expect(logState(lines).activity == .finished(at: t(6), summary: nil))
    }

    @Test func questionsAndPlansWaitForTheUser() {
        let asking = [
            Line.userMessage(at: t(1)),
            Line.assistantMessage(toolCalls: ["q"], at: t(2)),
            Line.toolStart("ask_user", id: "q", arguments: ["question": "Which DB?", "choices": ["A", "B"]], at: t(3)),
        ]
        let state = logState(asking)
        #expect(state.activity == .needsAnswer(PendingTool(
            callId: "q", name: "ask_user", startedAt: t(3), question: "Which DB?", choices: ["A", "B"]
        )))
        // Interaction tools aren't work steps.
        #expect(state.currentStep == nil)

        let answered = logState(asking + [Line.toolComplete(id: "q", at: t(4))])
        #expect(answered.activity == .working(since: t(1), detail: nil))

        let planning = logState([
            Line.userMessage(at: t(1)),
            Line.toolStart("exit_plan_mode", id: "p", arguments: ["summary": "1. Add tests"], at: t(2)),
        ])
        #expect(planning.activity == .needsPlanApproval(PendingTool(
            callId: "p", name: "exit_plan_mode", startedAt: t(2), choices: [], planSummary: "1. Add tests"
        )))
    }

    @Test func permissionsComeFirstThenQuestionsThenPlans() {
        var lines = [
            Line.userMessage(at: t(1)),
            Line.toolStart("exit_plan_mode", id: "p", arguments: ["summary": "Plan"], at: t(2)),
            Line.toolStart("ask_user", id: "q", arguments: ["question": "Sure?"], at: t(3)),
            Line.permissionRequested(id: "r1", ["kind": "shell", "fullCommandText": "first"], at: t(4)),
            Line.permissionRequested(id: "r2", ["kind": "shell", "fullCommandText": "second"], at: t(5)),
        ]
        func waitingOn() -> String? {
            switch logState(lines).activity {
            case .needsPermission(let permission): return permission.requestId
            case .needsAnswer(let tool), .needsPlanApproval(let tool): return tool.callId
            default: return nil
            }
        }
        #expect(waitingOn() == "r1")
        lines.append(Line.permissionCompleted(id: "r1", at: t(6)))
        #expect(waitingOn() == "r2")
        lines.append(Line.permissionCompleted(id: "r2", at: t(7)))
        #expect(waitingOn() == "q")
        lines.append(Line.toolComplete(id: "q", at: t(8)))
        #expect(waitingOn() == "p")
        lines.append(Line.toolComplete(id: "p", at: t(9)))
        #expect(logState(lines).activity == .working(since: t(1), detail: nil))
    }

    @Test func abortInterruptsButSubagentCancellationDoesNot() {
        let running = [
            Line.userMessage(at: t(1)),
            Line.assistantMessage(toolCalls: ["c1"], at: t(2)),
            Line.toolStart("task", id: "c1", arguments: ["description": "Explore"], at: t(3)),
        ]
        let cancelled = logState(running + [Line.abort("subagent_cancelled", at: t(4))])
        #expect(cancelled.activity == .working(since: t(1), detail: "Explore"))
        #expect(cancelled.pendingTools.keys.sorted() == ["c1"])

        let aborted = logState(running + [Line.abort(at: t(4))])
        #expect(aborted.activity == .interrupted(at: t(4)))
        #expect(aborted.pendingTools.isEmpty)
        #expect(aborted.currentStep == nil)
    }

    @Test func errorsFailUntilTheNextMessage() {
        let lines = [Line.userMessage(at: t(1)), Line.sessionError("Rate limited", at: t(2))]
        #expect(logState(lines).activity == .failed(at: t(2), message: "Rate limited"))

        let retried = logState(lines + [Line.userMessage(at: t(3))])
        #expect(retried.activity == .working(since: t(3), detail: nil))
        #expect(retried.errorMessage == nil)
    }

    @Test func shutdownInterruptsOnlyARunningTurn() {
        let midTurn = logState([
            Line.userMessage(at: t(1)),
            Line.toolStart("bash", id: "c1", arguments: ["description": "Build"], at: t(2)),
            Line.shutdown(at: t(3)),
        ])
        #expect(midTurn.activity == .interrupted(at: t(3)))
        #expect(midTurn.pendingTools.isEmpty)
        #expect(midTurn.currentStep == nil)

        let afterFinishing = logState([
            Line.userMessage(at: t(1)), Line.assistantMessage(at: t(2)), Line.turnEnd(at: t(3)), Line.shutdown(at: t(4)),
        ])
        #expect(afterFinishing.activity == .finished(at: t(3), summary: nil))
    }

    @Test func taskCompleteFinishesWithASummary() {
        let lines = [
            Line.userMessage(at: t(1)),
            Line.assistantMessage(toolCalls: ["c1"], at: t(2)),
            Line.toolStart("task_complete", id: "c1", arguments: ["summary": "Shipped it"], at: t(3)),
            Line.taskComplete("Shipped it", at: t(4)),
            Line.hook("agentStop", at: t(5)),
        ]
        let done = logState(lines)
        #expect(done.activity == .finished(at: t(4), summary: "Shipped it"))
        #expect(done.pendingTools.isEmpty)

        let next = logState(lines + [Line.userMessage(at: t(6))])
        #expect(next.summary == nil)
        #expect(next.activity == .working(since: t(6), detail: nil))
    }

    @Test func onlyTheMainAgentsStopHookFinishes() {
        let lines = [
            Line.userMessage(at: t(1)),
            Line.assistantMessage(toolCalls: ["c1"], at: t(2)),
            Line.toolStart("task", id: "c1", at: t(3)),
            Line.hook("agentStop", at: t(4), agentId: "sub-agent"),
        ]
        #expect(logState(lines).phase == .running)
        #expect(logState(lines + [Line.hook("agentStop", at: t(5))]).activity == .finished(at: t(5), summary: nil))
    }

    @Test func subagentEventsDoNotChangeTheMainAgent() {
        var lines = [
            Line.userMessage(at: t(1)),
            Line.assistantMessage(toolCalls: ["task1"], at: t(2)),
            Line.toolStart("task", id: "task1", arguments: ["description": "Explore"], at: t(3)),
            Line.userMessage("Explore the repo", at: t(4), agentId: "sub-agent"),
            Line.turnStart(at: t(5), subagent: true),
            Line.assistantMessage(toolCalls: ["s1"], at: t(6), subagent: true),
            Line.toolStart("bash", id: "s1", arguments: ["description": "grep"], at: t(7), subagent: true),
            Line.assistantMessage(at: t(8), subagent: true),
            Line.turnEnd(at: t(9), subagent: true),
            Line.toolComplete(id: "task1", at: t(10)),
        ]
        let state = logState(lines)
        #expect(state.activity == .working(since: t(1), detail: "Explore"))
        #expect(state.pendingTools.isEmpty)
        #expect(state.lastMainMessageHadTools)
        #expect(state.lastEventAt == t(10))

        lines += [Line.assistantMessage(at: t(11)), Line.turnEnd(at: t(12))]
        #expect(logState(lines).activity == .finished(at: t(12), summary: nil))
    }

    @Test func steeringMessagesKeepTheTurnGoing() {
        let state = logState([
            Line.userMessage(at: t(1)),
            Line.assistantMessage(toolCalls: ["c1"], at: t(2)),
            Line.toolStart("bash", id: "c1", arguments: ["description": "Long build"], at: t(3)),
            Line.userMessage("Also update the docs", at: t(4)),
        ])
        #expect(state.activity == .working(since: t(1), detail: "Long build"))
        #expect(state.pendingTools.keys.sorted() == ["c1"])
        #expect(state.lastMainMessageHadTools)
    }

    @Test func aNewMessageDropsWhatAnEndedTurnLeftBehind() {
        var lines = [
            Line.userMessage(at: t(1)),
            Line.assistantMessage(toolCalls: ["c1"], at: t(2)),
            Line.abort(at: t(3)),
            // A straggler logged after the abort.
            Line.toolStart("bash", id: "late", arguments: ["description": "Late"], at: t(4)),
        ]
        let interrupted = logState(lines)
        #expect(interrupted.activity == .interrupted(at: t(3)))
        #expect(interrupted.pendingTools.keys.sorted() == ["late"])

        lines.append(Line.userMessage(at: t(5)))
        let resumed = logState(lines)
        #expect(resumed.pendingTools.isEmpty)
        #expect(resumed.currentStep == nil)
        #expect(!resumed.lastMainMessageHadTools)

        // With the stale "asked for tools" flag cleared, a bare turn end finishes the new turn.
        lines.append(Line.turnEnd(at: t(6)))
        #expect(logState(lines).activity == .finished(at: t(6), summary: nil))
    }

    @Test func eventsWithoutTimestampsUseTheLatestKnownTime() {
        var state = SessionLogState()
        state.apply(LogEvent(timestamp: nil, kind: .userMessage))
        #expect(state.phase == .running)
        #expect(state.phaseSince == nil)

        state.apply(LogEvent(timestamp: t(2), kind: .turnStart(isSubagent: false)))
        #expect(state.phaseSince == t(2))

        state.apply(LogEvent(timestamp: t(5), kind: .other))
        state.apply(LogEvent(timestamp: nil, kind: .toolStart(.init(callId: "q", name: "ask_user", question: "Ok?"))))
        #expect(state.pendingTools["q"]?.startedAt == t(5))

        // Out-of-order timestamps never move the clock back.
        state.apply(LogEvent(timestamp: t(3), kind: .other))
        #expect(state.lastEventAt == t(5))

        state.apply(LogEvent(timestamp: nil, kind: .agentStop(isSubagent: false)))
        #expect(state.activity == .finished(at: t(5), summary: nil))
    }

    @Test func currentStepFollowsTheLatestMainToolCall() {
        var lines = [
            Line.userMessage(at: t(1)),
            Line.toolStart("view", id: "c1", title: "View README.md", at: t(2)),
        ]
        #expect(logState(lines).currentStep == "View README.md")

        lines.append(Line.toolStart("report_intent", id: "c2", arguments: ["intent": "Exploring"], at: t(3)))
        #expect(logState(lines).currentStep == "View README.md")

        lines.append(Line.toolStart("bash", id: "c3", arguments: ["description": "Run tests"], title: "Bash", at: t(4)))
        #expect(logState(lines).currentStep == "Run tests")

        lines.append(Line.toolStart("grep", id: "c4", at: t(5)))
        #expect(logState(lines).currentStep == nil)
    }

    @Test func aTailThatStartsMidTurnStillShowsTheTurn() {
        #expect(logState([Line.toolStart("bash", id: "c1", at: t(10))]).activity == .working(since: t(10), detail: nil))
        #expect(logState([Line.assistantMessage(at: t(10))]).phase == .running)
        #expect(logState([Line.turnStart(at: t(10))]).phase == .running)

        let permission = logState([
            Line.permissionRequested(id: "r1", ["kind": "url", "url": "https://github.com"], at: t(10)),
        ])
        #expect(permission.activity == .needsPermission(PendingPermission(
            requestId: "r1", kind: "url", detail: "https://github.com", requestedAt: t(10)
        )))

        #expect(logState([Line.turnEnd(at: t(10))]).phase == .unknown)
        #expect(logState([Line.turnStart(at: t(10), subagent: true)]).phase == .unknown)
        #expect(logState([Line.hook("agentStop", at: t(10))]).activity == .finished(at: t(10), summary: nil))
        #expect(logState([Line.taskComplete("Done", at: t(10))]).activity == .finished(at: t(10), summary: "Done"))
    }
}
