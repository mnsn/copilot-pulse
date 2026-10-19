import CoreServices
import Foundation

/// Thin wrapper over an FSEvents stream delivering file-level events on a dispatch queue.
/// The kernel pushes changes to us, so there is no polling and no CPU use while nothing changes.
public final class FileEventStream: @unchecked Sendable {
    public struct Event: Sendable {
        public var path: String
        public var flags: UInt32
    }

    /// Flags meaning events were coalesced or dropped and the caller should rescan everything.
    public static let rescanFlags = UInt32(
        kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged
    )

    private let paths: [String]
    private let latency: CFTimeInterval
    private let queue: DispatchQueue
    private let handler: @Sendable ([Event]) -> Void
    private var stream: FSEventStreamRef?

    public init(
        paths: [String], latency: CFTimeInterval = 0.15, queue: DispatchQueue,
        handler: @escaping @Sendable ([Event]) -> Void
    ) {
        self.paths = paths
        self.latency = latency
        self.queue = queue
        self.handler = handler
    }

    deinit {
        stop()
    }

    /// Call on `queue`.
    @discardableResult
    public func start() -> Bool {
        guard stream == nil else { return true }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let stream = Unmanaged<FileEventStream>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray
            var events: [Event] = []
            events.reserveCapacity(count)
            for index in 0..<count {
                guard let path = paths[index] as? String else { continue }
                events.append(Event(path: path, flags: eventFlags[index]))
            }
            stream.handler(events)
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
        ) else { return false }

        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return false
        }
        stream = created
        return true
    }

    /// Call on `queue`.
    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
