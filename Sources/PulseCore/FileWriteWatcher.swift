import Foundation

/// Watches one file for writes with kqueue, following its path when the file is replaced.
///
/// FSEvents reports a file's content changes only once the writer closes it, so it never sees a
/// process that keeps the file open, such as SQLite appending to its write-ahead log. kqueue
/// reports every write as it happens. Call `rearm()` whenever the path may point at a new file
/// (for example after FSEvents reports it was created); it's cheap when nothing changed.
///
/// Confined to `queue`: call everything there; `onChange` runs there too.
final class FileWriteWatcher: @unchecked Sendable {
    let path: String
    private let queue: DispatchQueue
    private let onChange: @Sendable () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var watchedID: FileInfo.ID?

    init(path: String, queue: DispatchQueue, onChange: @escaping @Sendable () -> Void) {
        self.path = path
        self.queue = queue
        self.onChange = onChange
    }

    deinit {
        source?.cancel()
    }

    var isArmed: Bool { source != nil }

    /// Watches the file currently at `path` unless it's already watched. Returns whether a file is watched.
    @discardableResult
    func rearm() -> Bool {
        if source != nil, let watchedID, FileInfo(path: path)?.id == watchedID {
            return true
        }
        cancel()
        let descriptor = open(path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        guard let info = FileInfo(descriptor: descriptor) else {
            close(descriptor)
            return false
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename, .revoke], queue: queue
        )
        source.setEventHandler { [weak self] in
            // A cancelled source never calls back, so `self.source` is the one that fired.
            guard let self, let events = self.source?.data else { return }
            if !events.isDisjoint(with: [.delete, .rename, .revoke]) {
                self.cancel()
                self.rearm()
            }
            self.onChange()
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
        watchedID = info.id
        return true
    }

    func cancel() {
        source?.cancel()
        source = nil
        watchedID = nil
    }
}
