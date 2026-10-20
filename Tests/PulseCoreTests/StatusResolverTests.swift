import Foundation
import Testing
@testable import PulseCore

private func meta(
    name: String = "Fix login", type: String = "project", running: Bool? = false, interrupted: Bool = false,
    updatedAt: Date? = t(0), workspaceId: String? = "w1", activity: ActivityPreview? = nil
) -> SessionMeta {
    SessionMeta(
        id: "s1", name: name, sessionType: type, mode: "interactive", isRunning: running, wasInterrupted: interrupted,
        updatedAt: updatedAt, projectName: "acme-web", branch: "fix-login", workspaceId: workspaceId,
        lastActivity: activity
    )
}

private func resolve(
    _ lines: [String]?, _ meta: SessionMeta, now: Date, options: ResolverOptions = ResolverOptions(),
    view: AppViewState = AppViewState(), acknowledgedAt: Date? = nil
) -> SessionSnapshot {
    StatusResolver.snapshot(
        for: SessionRecord(meta: meta, log: lines.map(logState)), now: now, options: options, view: view,
        acknowledgedAt: acknowledgedAt
    )
}

private func item(
    _ id: String, _ phase: DisplayPhase, since: Date?, name: String = "", reason: StatusReason = .idle
) -> SessionSnapshot {
    SessionSnapshot(
        id: id, name: name, isChat: false, phase: phase, reason: reason, headline: reason.headline, choices: [],
        since: since
    )
}

/// A turn that ended normally at t(3).
private let finishedTurn = [Line.userMessage(at: t(1)), Line.assistantMessage(at: t(2)), Line.turnEnd(at: t(3))]

@Suite struct StatusResolverTests {
    private func verify(
        _ snapshot: SessionSnapshot, _ phase: DisplayPhase, _ reason: StatusReason, since: Date?,
        detail: String? = nil, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(snapshot.phase == phase, sourceLocation: sourceLocation)
        #expect(snapshot.reason == reason, sourceLocation: sourceLocation)
        #expect(snapshot.headline == reason.headline, sourceLocation: sourceLocation)
        #expect(snapshot.since == since, sourceLocation: sourceLocation)
        #expect(snapshot.detail == detail, sourceLocation: sourceLocation)
    }

    @Test func carriesTheContextUsage() {
        var measured = meta()
        measured.contextUsage = ContextUsage(tokens: 120_000, limit: 200_000)
        #expect(resolve(finishedTurn, measured, now: t(10)).contextUsage == ContextUsage(tokens: 120_000, limit: 200_000))
        #expect(resolve(finishedTurn, meta(), now: t(10)).contextUsage == nil)
    }

    @Test func withoutALogTheAppsFlagsDecide() {
        verify(resolve(nil, meta(running: true, updatedAt: t(5)), now: t(10)), .running, .working, since: t(5))
        verify(resolve(nil, meta(interrupted: true, updatedAt: t(5)), now: t(10)), .stopped, .interrupted, since: t(5))
        verify(resolve(nil, meta(interrupted: true, updatedAt: t(5)), now: t(3_606)), .idle, .interrupted, since: t(5))
        verify(resolve(nil, meta(updatedAt: t(5)), now: t(10)), .idle, .idle, since: t(5))
        // A log without a turn in it says nothing either.
        let started = [Line.sessionStart(at: t(1))]
        verify(resolve(started, meta(running: true, updatedAt: t(5)), now: t(10)), .running, .working, since: t(5))
    }

    @Test func working() {
        let lines = [
            Line.userMessage(at: t(1)),
            Line.assistantMessage(toolCalls: ["c1"], at: t(2)),
            Line.toolStart("bash", id: "c1", arguments: ["description": "Run **unit** tests"], at: t(3)),
        ]
        verify(resolve(lines, meta(running: true), now: t(30)), .running, .working, since: t(1), detail: "Run unit tests")
    }

    @Test func questionsNeedYou() {
        let lines = [
            Line.userMessage(at: t(1)),
            Line.toolStart("ask_user", id: "q", arguments: [
                "question": "Use **Postgres** or `SQLite`?", "choices": ["Postgres", "SQLite"],
            ], at: t(2)),
        ]
        let snapshot = resolve(lines, meta(running: true), now: t(30))
        verify(snapshot, .needsYou, .question, since: t(2), detail: "Use Postgres or SQLite?")
        #expect(snapshot.choices == ["Postgres", "SQLite"])
    }

    @Test func plansNeedYou() {
        let lines = [
            Line.userMessage(at: t(1)),
            Line.toolStart("exit_plan_mode", id: "p", arguments: ["summary": "## Plan\n- Add tests\n- Ship it"], at: t(2)),
        ]
        verify(
            resolve(lines, meta(running: true), now: t(30)), .needsYou, .planApproval, since: t(2),
            detail: "Plan Add tests Ship it"
        )
    }

    @Test func permissionsNeedYou() {
        let cases: [([String: Any], String?)] = [
            (["kind": "shell", "fullCommandText": "rm -rf build"], "rm -rf build"),
            (["kind": "url"], "url"),
            ([:], nil),
        ]
        for (request, detail) in cases {
            let lines = [Line.userMessage(at: t(1)), Line.permissionRequested(id: "r1", request, at: t(2))]
            verify(resolve(lines, meta(running: true), now: t(30)), .needsYou, .permission, since: t(2), detail: detail)
        }
    }

    @Test func endedSessionsStayHighlightedForAnHour() {
        verify(resolve(finishedTurn, meta(), now: t(3_603)), .done, .finished, since: t(3))
        verify(resolve(finishedTurn, meta(), now: t(3_604)), .idle, .finished, since: t(3))
        let shortWindow = ResolverOptions(recentWindow: 60)
        verify(resolve(finishedTurn, meta(), now: t(64), options: shortWindow), .idle, .finished, since: t(3))
    }

    @Test func openingASessionFromPulseAcknowledgesIt() {
        verify(resolve(finishedTurn, meta(), now: t(60), acknowledgedAt: t(3)), .idle, .finished, since: t(3))
        verify(resolve(finishedTurn, meta(), now: t(60), acknowledgedAt: t(2)), .done, .finished, since: t(3))
    }

    @Test func theAppsUnreadMarkersTellWhatWasSeen() {
        func phase(_ session: SessionMeta, unread: Set<String>?, updatedAt: Date?) -> DisplayPhase {
            let view = AppViewState(unreadWorkspaceIds: unread, unreadUpdatedAt: updatedAt)
            return resolve(finishedTurn, session, now: t(60), view: view).phase
        }
        #expect(phase(meta(), unread: [], updatedAt: t(10)) == .idle)
        #expect(phase(meta(), unread: ["w9"], updatedAt: t(10)) == .idle)
        #expect(phase(meta(), unread: ["w1"], updatedAt: t(10)) == .done)
        // A marker list older than the end of the turn can't have been cleared for it.
        #expect(phase(meta(), unread: [], updatedAt: t(2)) == .done)
        #expect(phase(meta(), unread: nil, updatedAt: t(10)) == .done)
        #expect(phase(meta(type: "general_chat", workspaceId: nil), unread: [], updatedAt: t(10)) == .done)
    }

    @Test func aRunningLogTheAppNoLongerRunsGoesStale() {
        let lines = [
            Line.userMessage(at: t(1)),
            Line.assistantMessage(toolCalls: ["c1"], at: t(2)),
            Line.toolStart("bash", id: "c1", at: t(3)),
        ]
        verify(resolve(lines, meta(), now: t(93)), .running, .working, since: t(1))
        verify(resolve(lines, meta(), now: t(94)), .stopped, .unresponsive, since: t(3))
        verify(resolve(lines, meta(interrupted: true), now: t(94)), .stopped, .interrupted, since: t(3))
        verify(resolve(lines, meta(), now: t(3_604)), .idle, .unresponsive, since: t(3))
        // While the app still says it's running, silence alone means nothing.
        verify(resolve(lines, meta(running: true), now: t(10_000)), .running, .working, since: t(1))
    }

    /// The fallback query and the folder scan can't tell whether the app is running a session.
    @Test func anUnknownRunningFlagLeavesItToTheLog() {
        let asking = [
            Line.userMessage(at: t(1)),
            Line.toolStart("ask_user", id: "q", arguments: ["question": "Ship it?"], at: t(2)),
        ]
        // A question can wait for hours; only a flag known to be off means the CLI is gone.
        verify(resolve(asking, meta(running: nil), now: t(10_000)), .needsYou, .question, since: t(2), detail: "Ship it?")
        verify(resolve(asking, meta(running: false), now: t(10_000)), .idle, .unresponsive, since: t(2))
        let working = [Line.userMessage(at: t(1)), Line.toolStart("bash", id: "c1", at: t(2))]
        verify(resolve(working, meta(running: nil), now: t(10_000)), .running, .working, since: t(1))
        // Nor does it start a new turn or stand in for a missing log.
        verify(resolve(finishedTurn, meta(running: nil, updatedAt: t(10)), now: t(20)), .done, .finished, since: t(3))
        verify(resolve(nil, meta(running: nil, updatedAt: t(5)), now: t(10)), .idle, .idle, since: t(5))
    }

    @Test func aNewTurnTheLogHasNotCaughtUpWithIsStarting() {
        verify(resolve(finishedTurn, meta(running: true, updatedAt: t(10)), now: t(20)), .running, .starting, since: t(10))
        // The grace period is over.
        verify(resolve(finishedTurn, meta(running: true, updatedAt: t(10)), now: t(130)), .done, .finished, since: t(3))
        // The app's timestamp belongs to the turn the log already shows.
        verify(resolve(finishedTurn, meta(running: true, updatedAt: t(4)), now: t(20)), .done, .finished, since: t(3))
    }

    @Test func endedTurnsShowTheAppsLastMessage() {
        func detail(_ lines: [String], _ activity: ActivityPreview) -> String? {
            resolve(lines, meta(activity: activity), now: t(60)).detail
        }
        func idle(_ text: String, at date: Date?) -> ActivityPreview {
            ActivityPreview(kind: "agent_idle", text: text, at: date)
        }
        #expect(detail(finishedTurn, idle("I fixed the **login** bug", at: t(4))) == "I fixed the login bug")
        #expect(detail(finishedTurn, idle("Undated", at: nil)) == "Undated")
        #expect(detail(finishedTurn, idle("Just in time", at: t(-27))) == "Just in time")
        // From an earlier turn, about something else, or empty.
        #expect(detail(finishedTurn, idle("Too old", at: t(-28))) == nil)
        #expect(detail(finishedTurn, ActivityPreview(kind: "agent_asking", text: "A question", at: t(4))) == nil)
        #expect(detail(finishedTurn, idle("", at: t(4))) == nil)

        // The CLI's own summary wins.
        let completed = [Line.userMessage(at: t(1)), Line.taskComplete("Shipped **it**", at: t(2))]
        #expect(detail(completed, idle("Preview", at: t(2))) == "Shipped it")
    }

    @Test func failuresAndInterruptions() {
        let failed = [Line.userMessage(at: t(1)), Line.sessionError("Rate limit exceeded", at: t(2))]
        verify(resolve(failed, meta(), now: t(60)), .stopped, .failed, since: t(2), detail: "Rate limit exceeded")

        let failedQuietly = [Line.userMessage(at: t(1)), Line.event("session.error", data: ["errorType": "query"], at: t(2))]
        let errorPreview = ActivityPreview(kind: "agent_error", text: "Something broke", at: t(2))
        verify(
            resolve(failedQuietly, meta(activity: errorPreview), now: t(60)), .stopped, .failed, since: t(2),
            detail: "Something broke"
        )

        let aborted = [Line.userMessage(at: t(1)), Line.abort(at: t(2))]
        let idlePreview = ActivityPreview(kind: "agent_idle", text: "Earlier reply", at: t(2))
        verify(resolve(aborted, meta(activity: idlePreview), now: t(60)), .stopped, .interrupted, since: t(2))
    }

    @Test func namesAndContextPassThrough() {
        let snapshot = resolve(nil, meta(name: "  Fix   the\nlogin  "), now: t(10))
        #expect(snapshot.name == "Fix the login")
        #expect(snapshot.displayName == "Fix the login")
        #expect(snapshot.id == "s1")
        #expect(snapshot.projectName == "acme-web")
        #expect(snapshot.branch == "fix-login")
        #expect(snapshot.mode == "interactive")
        #expect(!snapshot.isChat)

        #expect(resolve(nil, meta(name: " "), now: t(10)).displayName == "Untitled session")
        let chat = resolve(nil, meta(name: "", type: "general_chat", workspaceId: nil), now: t(10))
        #expect(chat.isChat)
        #expect(chat.displayName == "Untitled chat")
    }

    @Test(arguments: [
        ("**Bold** and `code`", "Bold and code"),
        ("__Underlined__ words", "Underlined words"),
        ("See [the docs](https://example.com/docs) now", "See the docs now"),
        ("![diagram](chart.png) above", "diagram above"),
        ("Cut off [link](https://exam", "Cut off link"),
        ("# Title\n> Quote\n- Item\n2. Step", "Title Quote Item Step"),
        ("  spaced \n\n out\t", "spaced out"),
        ("Plain text", "Plain text"),
    ])
    func flattensMarkdown(_ markdown: String, _ expected: String) {
        #expect(PlainText.fromMarkdown(markdown) == expected)
    }

    @Test(arguments: [
        (0.0, "now"), (59, "now"), (60, "1m"), (3_599, "59m"), (3_600, "1h"), (3_660, "1h 1m"),
        (86_399, "23h 59m"), (86_400, "1d"), (200_000, "2d"), (-5, "now"),
    ])
    func formatsElapsedTime(_ seconds: TimeInterval, _ expected: String) {
        #expect(Elapsed.short(since: t(0), now: t(seconds)) == expected)
    }

    @Test func elapsedTimeOfNothingIsEmpty() {
        #expect(Elapsed.short(since: nil, now: t(0)) == "")
    }

    @Test func orderingPutsWhatNeedsYouFirst() {
        let snapshots = [
            item("idle-undated", .idle, since: nil),
            item("running-old", .running, since: t(1)),
            item("asking-new", .needsYou, since: t(10)),
            item("done", .done, since: t(3)),
            item("idle", .idle, since: t(50)),
            item("running-new", .running, since: t(20)),
            item("asking-old", .needsYou, since: t(5)),
            item("stopped", .stopped, since: t(4)),
            item("tie-10", .done, since: t(2), name: "Session 10"),
            item("tie-2", .done, since: t(2), name: "Session 2"),
            item("same-b", .done, since: t(1), name: "Same"),
            item("same-a", .done, since: t(1), name: "Same"),
        ]
        #expect(SessionOrdering.sorted(snapshots.shuffled()).map(\.id) == [
            "asking-old", "asking-new", "running-new", "running-old",
            "done", "tie-2", "tie-10", "same-a", "same-b", "stopped", "idle", "idle-undated",
        ])
    }

    @Test func countsPhases() {
        let phases: [DisplayPhase] = [.needsYou, .needsYou, .running, .done, .stopped, .idle, .idle, .idle]
        let counts = PhaseCounts(phases.enumerated().map { item("\($0.offset)", $0.element, since: nil) })
        #expect(DisplayPhase.allCases.map { counts[$0] } == [2, 1, 1, 1, 3])
        #expect(counts.active == 5)

        var edited = PhaseCounts()
        edited[.done] += 2
        #expect(edited.done == 2)
        #expect(edited.active == 2)
    }

    @Test func phasesSortByUrgency() {
        #expect(DisplayPhase.allCases.shuffled().sorted() == [.needsYou, .running, .done, .stopped, .idle])
        let reasons: [StatusReason] = [
            .question, .planApproval, .permission, .working, .starting,
            .finished, .interrupted, .failed, .unresponsive, .idle,
        ]
        #expect(reasons.filter { item("s", .idle, since: nil, reason: $0).isEnded }
            == [.finished, .interrupted, .failed, .unresponsive])
    }
}
