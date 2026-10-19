import AppKit
import Combine
import PulseCore

/// Main-thread view model: turns engine snapshots into the sorted, resolved session list.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [SessionSnapshot] = []
    @Published private(set) var counts = PhaseCounts()
    /// Reference time for relative labels; ticks every 15 s.
    @Published private(set) var now = Date()
    @Published private(set) var problem: String?
    @Published private(set) var hasLoaded = false

    private let settings: AppSettings
    private var engine: SessionEngine?
    private var state = EngineSnapshot()
    private var ticker: Timer?
    private var cancellables: Set<AnyCancellable> = []

    init(settings: AppSettings) {
        self.settings = settings
    }

    var activeSessions: [SessionSnapshot] { sessions.filter { $0.phase != .idle } }

    func sessions(in phase: DisplayPhase) -> [SessionSnapshot] {
        sessions.filter { $0.phase == phase }
    }

    func start() {
        guard engine == nil else { return }
        let engine = SessionEngine { [weak self] state in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.receive(state) }
            }
        }
        self.engine = engine
        engine.start()

        settings.$keepEndedMinutes.map { _ in () }
            .merge(with: settings.$acknowledged.map { _ in () })
            .dropFirst(2)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in MainActor.assumeIsolated { self?.recompute() } }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.recompute() } }
            .store(in: &cancellables)

        let ticker = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recompute() }
        }
        ticker.tolerance = 3
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    func refresh() {
        engine?.refresh()
    }

    /// Opens the session in the Copilot app; opening a finished one also dismisses it.
    func open(_ session: SessionSnapshot) {
        if session.phase == .done || session.phase == .stopped {
            settings.acknowledge([session.id])
        }
        CopilotApp.open(sessionId: session.id)
    }

    func clear(_ phase: DisplayPhase) {
        settings.acknowledge(sessions(in: phase).map(\.id))
    }

    func receive(_ state: EngineSnapshot) {
        self.state = state
        hasLoaded = true
        if problem != state.problem {
            problem = state.problem
            if let problem { Log.app.error("\(problem, privacy: .public)") }
        }
        recompute()
    }

    private func recompute() {
        let now = Date()
        let options = ResolverOptions(recentWindow: TimeInterval(settings.keepEndedMinutes * 60))
        var resolved = state.records.map {
            StatusResolver.snapshot(
                for: $0, now: now, options: options, view: state.view, acknowledgedAt: settings.acknowledged[$0.id]
            )
        }

        // A session the user is looking at in the Copilot app right now doesn't need highlighting.
        if CopilotApp.isFrontmost, let viewed = state.view.viewedSessionId,
           let index = resolved.firstIndex(where: { $0.id == viewed }),
           resolved[index].phase == .done || resolved[index].phase == .stopped {
            settings.acknowledge([viewed], at: now)
            resolved[index] = StatusResolver.snapshot(
                for: state.records[index], now: now, options: options, view: state.view, acknowledgedAt: now
            )
        }

        let sorted = SessionOrdering.sorted(resolved)
        self.now = now
        if sorted != sessions { sessions = sorted }
        let newCounts = PhaseCounts(sorted)
        if newCounts != counts { counts = newCounts }
    }
}
