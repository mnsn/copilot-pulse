import Foundation

/// Follows one session's append-only `events.jsonl`.
///
/// The first load reads only the file's tail (growing it until a `user.message` anchor is found),
/// later updates read just the appended bytes. A replaced, truncated or rewritten file triggers a
/// fresh load. Not thread-safe: confine each reader to a single queue.
public final class EventLogReader {
    public static let defaultTailChunkSizes = [512 << 10, 4 << 20, 16 << 20]
    private static let boundaryLength = 64

    public let url: URL
    public private(set) var state = SessionLogState()
    public private(set) var isLoaded = false

    private let tailChunkSizes: [Int]
    private let maxIncrementalRead: UInt64
    private var offset: UInt64 = 0
    private var fileID: FileInfo.ID?
    private var modified: Int64 = 0
    /// The last bytes before `offset`. If they change, the file was rewritten rather than appended to.
    private var boundary = Data()
    private var carry = Data()

    public init(
        url: URL,
        tailChunkSizes: [Int] = EventLogReader.defaultTailChunkSizes,
        maxIncrementalRead: UInt64 = 32 << 20
    ) {
        precondition(!tailChunkSizes.isEmpty, "tailChunkSizes must not be empty")
        self.url = url
        self.tailChunkSizes = tailChunkSizes
        self.maxIncrementalRead = maxIncrementalRead
    }

    /// Catches up with the file. Returns true when the derived state changed.
    @discardableResult
    public func update() -> Bool {
        let previousState = state
        let wasLoaded = isLoaded
        // A vanished file keeps its last known state; the session list decides visibility.
        guard let info = FileInfo(path: url.path) else { return false }

        if !isLoaded || info.id != fileID || info.size < offset || info.size - offset > maxIncrementalRead {
            loadTail(info)
        } else if info.size > offset || info.modified != modified {
            if !readAppended(info) { loadTail(info) }
        }
        return state != previousState || isLoaded != wasLoaded
    }

    private func loadTail(_ info: FileInfo) {
        state = SessionLogState()
        carry = Data()
        boundary = Data()
        offset = 0
        fileID = info.id
        modified = info.modified
        isLoaded = true
        let size = info.size
        guard size > 0 else { return }

        for (attempt, chunkSize) in tailChunkSizes.enumerated() {
            let start = size > UInt64(chunkSize) ? size - UInt64(chunkSize) : 0
            // Read one extra byte so we can tell whether `start` already sits on a line boundary.
            let readFrom = start > 0 ? start - 1 : 0
            guard let data = read(from: readFrom, upTo: size) else {
                isLoaded = false
                return
            }
            var events: [LogEvent] = []
            let remainder = Self.forEachLine(in: data, skipFirstPartial: readFrom > 0) { line in
                if let event = EventLineParser.parse(line) { events.append(event) }
            }
            let isLastAttempt = attempt == tailChunkSizes.count - 1
            if start == 0 || isLastAttempt || events.contains(where: { $0.kind.isAnchor }) {
                var fresh = SessionLogState()
                fresh.apply(events)
                state = fresh
                carry = remainder
                offset = readFrom + UInt64(data.count)
                boundary = Data(data.suffix(Self.boundaryLength))
                return
            }
        }
    }

    /// Reads what was appended since the last update. Returns false if the bytes before the old end
    /// changed, which means the file was rewritten in place. A failed read changes nothing and is
    /// retried on the next update.
    private func readAppended(_ info: FileInfo) -> Bool {
        let start = offset - UInt64(boundary.count)
        guard let data = read(from: start, upTo: info.size) else { return true }
        guard data.count >= boundary.count, data.prefix(boundary.count) == boundary else { return false }
        modified = info.modified
        guard data.count > boundary.count else { return true }

        offset = start + UInt64(data.count)
        var buffer = carry
        buffer.append(data.dropFirst(boundary.count))
        boundary = Data(data.suffix(Self.boundaryLength))
        var next = state
        carry = Self.forEachLine(in: buffer, skipFirstPartial: false) { line in
            if let event = EventLineParser.parse(line) { next.apply(event) }
        }
        state = next
        return true
    }

    private func read(from start: UInt64, upTo end: UInt64) -> Data? {
        guard end > start else { return Data() }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: start)
            return try handle.read(upToCount: Int(end - start)) ?? Data()
        } catch {
            return nil
        }
    }

    /// Calls `body` for each complete line and returns the trailing partial line, if any.
    static func forEachLine(
        in data: Data, skipFirstPartial: Bool, _ body: (UnsafeRawBufferPointer) -> Void
    ) -> Data {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data in
            guard let base = raw.baseAddress, !raw.isEmpty else { return Data() }
            let end = raw.count
            var start = 0
            if skipFirstPartial {
                guard let newline = memchr(base, 0x0A, end) else { return Data() }
                start = base.distance(to: UnsafeRawPointer(newline)) + 1
            }
            while start < end, let newline = memchr(base + start, 0x0A, end - start) {
                let lineEnd = base.distance(to: UnsafeRawPointer(newline))
                if lineEnd > start {
                    body(UnsafeRawBufferPointer(start: base + start, count: lineEnd - start))
                }
                start = lineEnd + 1
            }
            return start < end ? Data(bytes: base + start, count: end - start) : Data()
        }
    }
}

struct FileInfo {
    struct ID: Equatable {
        var device: Int64
        var inode: UInt64
    }

    var id: ID
    var size: UInt64
    /// Modification time in nanoseconds since 1970.
    var modified: Int64

    init?(path: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        self.init(info)
    }

    init?(descriptor: Int32) {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return nil }
        self.init(info)
    }

    private init(_ info: stat) {
        id = ID(device: Int64(info.st_dev), inode: UInt64(info.st_ino))
        size = UInt64(max(0, info.st_size))
        modified = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
    }
}
