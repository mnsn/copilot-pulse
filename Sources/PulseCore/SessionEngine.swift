import Foundation

public struct SessionRecord: Sendable, Equatable, Identifiable {
    public var meta: SessionMeta
    /// Nil when the session has no event log yet.
    public var log: SessionLogState?

    public var id: String { meta.id }

    public init(meta: SessionMeta, log: SessionLogState?) {
        self.meta = meta
        self.log = log
    }
}

/// Everything the engine knows at one point in time.
public struct EngineSnapshot: Sendable, Equatable {
    public var records: [SessionRecord]
    public var view: AppViewState
    /// Set when the Copilot data couldn't be read (shown in the UI instead of an empty list).
    public var problem: String?

    public init(records: [SessionRecord] = [], view: AppViewState = AppViewState(), problem: String? = nil) {
        self.records = records
        self.view = view
        self.problem = problem
    }
}

/// Watches `~/.copilot` with FSEvents and keeps one `EventLogReader` per visible session.
/// Event-log appends are applied immediately; database changes trigger a throttled metadata
/// reload. The app keeps its database open, and FSEvents only reports a file's writes once it's
/// closed, so database commits are picked up by a kqueue watch on SQLite's write-ahead log.
/// A slow safety rescan covers anything the watches might miss.
///
/// All mutable state is confined to `queue`; `onChange` is called on that queue.
public final class SessionEngine: @unchecked Sendable {
    public typealias ChangeHandler = @Sendable (EngineSnapshot) -> Void

    public let paths: CopilotPaths
    private let queue: DispatchQueue
    private let onChange: ChangeHandler
    private let metadataThrottle: TimeInterval
    private let safetyInterval: TimeInterval

    private var metas: [SessionMeta] = []
    private var view = AppViewState()
    private var problem: String?
    private var metadataFromDatabase = false
    private var readers: [String: EventLogReader] = [:]
    private var lastPublished: EngineSnapshot?
    private var stream: FileEventStream?
    private var walWatcher: FileWriteWatcher?
    private var safetyTimer: DispatchSourceTimer?
    private var metadataReloadScheduled = false
    private var isActive = false

    public init(
        paths: CopilotPaths = .default(),
        metadataThrottle: TimeInterval = 0.25,
        safetyInterval: TimeInterval = 60,
        onChange: @escaping ChangeHandler
    ) {
        self.paths = paths
        self.queue = DispatchQueue(label: "CopilotPulse.SessionEngine", qos: .utility)
        self.metadataThrottle = metadataThrottle
        self.safetyInterval = safetyInterval
        self.onChange = onChange
    }

    public func start() {
        queue.async { [self] in
            guard !isActive else { return }
            isActive = true
            // Watch before the first load so no change can slip in between.
            startWatching()
            reloadMetadata()
            publish(force: true)
            startSafetyTimer()
        }
    }

    public func stop() {
        queue.async { [self] in
            isActive = false
            stream?.stop()
            stream = nil
            walWatcher?.cancel()
            walWatcher = nil
            safetyTimer?.cancel()
            safetyTimer = nil
        }
    }

    /// Re-reads metadata and all logs, then publishes if anything changed.
    public func refresh() {
        queue.async { [self] in
            guard isActive else { return }
            rescan()
        }
    }

    /// One-shot synchronous load (CLI and tests).
    public static func loadOnce(paths: CopilotPaths = .default()) -> EngineSnapshot {
        let engine = SessionEngine(paths: paths) { _ in }
        return engine.queue.sync {
            engine.reloadMetadata()
            return engine.currentSnapshot()
        }
    }

    // MARK: - Queue-confined

    private func startWatching() {
        let stream = FileEventStream(paths: [paths.root.path], latency: 0.15, queue: queue) { [weak self] events in
            self?.handle(events)
        }
        if stream.start() {
            self.stream = stream
        }
        let walWatcher = FileWriteWatcher(path: paths.databaseWAL.path, queue: queue) { [weak self] in
            self?.scheduleMetadataReload()
        }
        // The log may not exist yet (e.g. the app isn't running); FSEvents reports its creation.
        walWatcher.rearm()
        self.walWatcher = walWatcher
    }

    private func startSafetyTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + safetyInterval, repeating: safetyInterval, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            guard let self, self.isActive else { return }
            self.rescan()
        }
        timer.resume()
        safetyTimer = timer
    }

    private func handle(_ events: [FileEventStream.Event]) {
        guard isActive else { return }
        var touchedSessions = Set<String>()
        var databaseChanged = false
        var walChanged = false
        var mustRescan = false

        for event in events {
            if event.flags & FileEventStream.rescanFlags != 0 {
                mustRescan = true
                continue
            }
            let path = event.path
            if path.hasSuffix("/events.jsonl") {
                let sessionDirectory = (path as NSString).deletingLastPathComponent
                let container = ((sessionDirectory as NSString).deletingLastPathComponent as NSString).lastPathComponent
                if container == "session-state" {
                    touchedSessions.insert((sessionDirectory as NSString).lastPathComponent)
                }
            } else if path.hasSuffix("/data.db-wal") {
                // Created, removed or closed: the kqueue watch may need to move to a new file.
                walChanged = true
                databaseChanged = true
            } else if path.hasSuffix("/data.db") || path.hasSuffix("/data.db-journal") {
                databaseChanged = true
            }
        }

        if mustRescan {
            rescan()
            return
        }
        if walChanged {
            walWatcher?.rearm()
        }
        for id in touchedSessions {
            readers[id]?.update()
        }
        if databaseChanged {
            scheduleMetadataReload()
        }
        if !touchedSessions.isEmpty {
            publish()
        }
    }

    private func scheduleMetadataReload() {
        guard !metadataReloadScheduled else { return }
        metadataReloadScheduled = true
        queue.asyncAfter(deadline: .now() + metadataThrottle) { [weak self] in
            guard let self else { return }
            self.metadataReloadScheduled = false
            guard self.isActive else { return }
            self.reloadMetadata()
            self.publish()
        }
    }

    private func rescan() {
        walWatcher?.rearm()
        reloadMetadata()
        for reader in readers.values {
            reader.update()
        }
        publish()
    }

    private func reloadMetadata() {
        do {
            let snapshot = try AppDatabase.load(at: paths.database)
            metas = snapshot.sessions
            view = snapshot.view
            metadataFromDatabase = true
            problem = nil
        } catch {
            if metadataFromDatabase {
                // Keep the last good list, but its running flags may be out of date, so the
                // logs decide until the database can be read again.
                for index in metas.indices {
                    metas[index].isRunning = nil
                }
                problem = "\(error). The list may be out of date."
            } else {
                metas = SessionStateScanner.recentSessions(paths: paths)
                problem = FileManager.default.fileExists(atPath: paths.root.path)
                    ? String(describing: error)
                    : "No Copilot data found at \(paths.root.path)"
            }
        }
        syncReaders()
    }

    private func syncReaders() {
        let visible = Set(metas.map(\.id))
        readers = readers.filter { visible.contains($0.key) }
        for id in visible where readers[id] == nil {
            let reader = EventLogReader(url: paths.eventsFile(id))
            reader.update()
            readers[id] = reader
        }
    }

    private func currentSnapshot() -> EngineSnapshot {
        let records = metas.map { meta in
            let reader = readers[meta.id]
            return SessionRecord(meta: meta, log: reader?.isLoaded == true ? reader?.state : nil)
        }
        return EngineSnapshot(records: records, view: view, problem: problem)
    }

    private func publish(force: Bool = false) {
        let current = currentSnapshot()
        guard force || current != lastPublished else { return }
        lastPublished = current
        onChange(current)
    }
}
