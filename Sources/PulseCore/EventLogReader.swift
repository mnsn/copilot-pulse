import Foundation

/// Follows one session's append-only `events.jsonl`.
///
/// The first load reads only the file's tail (growing it until a `user.message` anchor is found),
/// later updates read just the appended bytes. A replaced or truncated file triggers a fresh load.
/// Not thread-safe: confine each reader to a single queue.
public final class EventLogReader {
    public static let defaultTailChunkSizes = [512 << 10, 4 << 20, 16 << 20]

    public let url: URL
    public private(set) var state = SessionLogState()
    public private(set) var isLoaded = false

    private let tailChunkSizes: [Int]
    private let maxIncrementalRead: UInt64
    private var offset: UInt64 = 0
    private var fileID: FileInfo.ID?
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
        } else if info.size > offset {
            readAppended(upTo: info.size)
        }
        return state != previousState || isLoaded != wasLoaded
    }

    private func loadTail(_ info: FileInfo) {
        state = SessionLogState()
        carry = Data()
        offset = 0
        fileID = info.id
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
                return
            }
        }
    }

    private func readAppended(upTo size: UInt64) {
        guard let data = read(from: offset, upTo: size), !data.isEmpty else { return }
        offset += UInt64(data.count)
        var buffer = carry
        buffer.append(data)
        var next = state
        carry = Self.forEachLine(in: buffer, skipFirstPartial: false) { line in
            if let event = EventLineParser.parse(line) { next.apply(event) }
        }
        state = next
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
    }
}
