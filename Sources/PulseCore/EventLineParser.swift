import Foundation

/// Parses one `events.jsonl` line into a `LogEvent`.
///
/// Lines can be megabytes long (tool output, file contents), so irrelevant event types are
/// classified from their leading `{"type":"…"` bytes and only state-relevant ones are JSON-decoded.
public enum EventLineParser {
    private static let typePrefix = Array(#"{"type":""#.utf8)
    private static let timestampKey = Array(#""timestamp":""#.utf8)
    private static let agentStopNeedle = Array(#""hookType":"agentStop""#.utf8)
    private static let topLevelAgentIdKey = Array(#"},"agentId":""#.utf8)
    private static let toolCompletePrefix = Array(#"{"type":"tool.execution_complete","data":{"toolCallId":""#.utf8)

    /// Types whose payload we don't need; the type and the trailing timestamp suffice.
    private static let headerOnlyTypes: [String: LogEvent.Kind] = [
        "user.message": .userMessage,
        "session.start": .sessionStart,
        "session.resume": .sessionResume,
        "session.shutdown": .sessionShutdown,
    ]

    private static let decodedTypes: Set<String> = [
        "assistant.turn_start", "assistant.turn_end", "assistant.message",
        "tool.execution_start", "tool.execution_complete",
        "permission.requested", "permission.completed",
        "hook.start", "abort", "session.error", "session.task_complete",
    ]

    public static func parse(_ line: String) -> LogEvent? {
        var copy = line
        return copy.withUTF8 { parse(UnsafeRawBufferPointer($0)) }
    }

    public static func parse(_ raw: UnsafeRawBufferPointer) -> LogEvent? {
        let line = trimmed(raw)
        guard line.count >= 2 else { return nil }

        if let type = fastType(line) {
            if let kind = headerOnlyTypes[type] {
                let isSubagentMessage = kind == .userMessage && hasTopLevelAgentId(line)
                return LogEvent(timestamp: tailTimestamp(line), kind: isSubagentMessage ? .other : kind)
            }
            if type == "tool.execution_complete", let callId = fastToolCompleteId(line) {
                return LogEvent(timestamp: tailTimestamp(line), kind: .toolComplete(callId: callId))
            }
            if !decodedTypes.contains(type) || (type == "hook.start" && !contains(line, agentStopNeedle)) {
                return LogEvent(timestamp: tailTimestamp(line), kind: .other)
            }
        }

        guard let object = decode(line) else { return nil }
        return event(from: object)
    }

    // MARK: - Full decode

    static func event(from object: [String: Any]) -> LogEvent? {
        guard let type = object["type"] as? String else { return nil }
        let data = object["data"] as? [String: Any] ?? [:]
        let timestamp = (object["timestamp"] as? String).flatMap(Timestamp.parse)
        let isSubagent = nonEmpty(data["parentToolCallId"]) != nil || nonEmpty(object["agentId"]) != nil

        let kind: LogEvent.Kind
        switch type {
        case "user.message":
            kind = isSubagent ? .other : .userMessage
        case "assistant.turn_start":
            kind = .turnStart(isSubagent: isSubagent)
        case "assistant.turn_end":
            kind = .turnEnd(isSubagent: isSubagent)
        case "assistant.message":
            let hasTools = (data["toolRequests"] as? [Any]).map { !$0.isEmpty } ?? false
            kind = .assistantMessage(isSubagent: isSubagent, hasToolRequests: hasTools)
        case "tool.execution_start":
            guard let callId = nonEmpty(data["toolCallId"]) else { kind = .other; break }
            let name = data["toolName"] as? String ?? ""
            let arguments = data["arguments"] as? [String: Any] ?? [:]
            kind = .toolStart(LogEvent.ToolStart(
                callId: callId,
                name: name,
                isSubagent: isSubagent,
                title: nonEmpty(data["toolTitle"]),
                description: nonEmpty(arguments["description"]),
                question: name == "ask_user" ? nonEmpty(arguments["question"]) : nil,
                choices: name == "ask_user" ? stringArray(arguments["choices"]) : [],
                planSummary: name == "exit_plan_mode" ? nonEmpty(arguments["summary"]) : nil
            ))
        case "tool.execution_complete":
            guard let callId = nonEmpty(data["toolCallId"]) else { kind = .other; break }
            kind = .toolComplete(callId: callId)
        case "permission.requested":
            guard let requestId = nonEmpty(data["requestId"]) else { kind = .other; break }
            let request = data["permissionRequest"] as? [String: Any] ?? [:]
            kind = .permissionRequested(LogEvent.PermissionRequest(
                requestId: requestId,
                kind: nonEmpty(request["kind"]),
                detail: permissionDetail(request)
            ))
        case "permission.completed":
            guard let requestId = nonEmpty(data["requestId"]) else { kind = .other; break }
            kind = .permissionCompleted(requestId: requestId)
        case "hook.start":
            kind = data["hookType"] as? String == "agentStop" ? .agentStop(isSubagent: isSubagent) : .other
        case "abort":
            kind = .abort(reason: nonEmpty(data["reason"]))
        case "session.error":
            kind = .sessionError(errorType: nonEmpty(data["errorType"]), message: nonEmpty(data["message"]))
        case "session.start":
            kind = .sessionStart
        case "session.resume":
            kind = .sessionResume
        case "session.shutdown":
            kind = .sessionShutdown
        case "session.task_complete":
            kind = .taskComplete(summary: nonEmpty(data["summary"]), success: data["success"] as? Bool)
        default:
            kind = .other
        }
        return LogEvent(timestamp: timestamp, kind: kind)
    }

    private static func permissionDetail(_ request: [String: Any]) -> String? {
        if let extensionName = nonEmpty(request["extensionName"]) {
            return "\(extensionName) extension wants access"
        }
        let keys = ["intention", "fullCommandText", "commandText", "command", "toolTitle",
                    "toolName", "serverName", "fileName", "path", "url"]
        for key in keys {
            if let value = nonEmpty(request[key]) { return value }
        }
        return nil
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func stringArray(_ value: Any?) -> [String] {
        (value as? [Any] ?? []).compactMap { nonEmpty($0) }
    }

    private static func decode(_ line: UnsafeRawBufferPointer) -> [String: Any]? {
        guard let base = line.baseAddress, !line.isEmpty else { return nil }
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: line.count, deallocator: .none)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Byte-level helpers

    private static func trimmed(_ raw: UnsafeRawBufferPointer) -> UnsafeRawBufferPointer {
        func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0D || byte == 0x0A }
        var start = 0
        var end = raw.count
        while start < end, isSpace(raw[start]) { start += 1 }
        while end > start, isSpace(raw[end - 1]) { end -= 1 }
        return UnsafeRawBufferPointer(rebasing: raw[start..<end])
    }

    private static func hasPrefix(_ line: UnsafeRawBufferPointer, _ prefix: [UInt8]) -> Bool {
        guard line.count > prefix.count else { return false }
        for index in 0..<prefix.count where line[index] != prefix[index] { return false }
        return true
    }

    /// Reads a JSON string value starting at `start` up to its closing quote; nil if it contains escapes.
    private static func simpleString(_ line: UnsafeRawBufferPointer, from start: Int) -> String? {
        var end = start
        while end < line.count {
            let byte = line[end]
            if byte == 0x22 { break }
            if byte == 0x5C { return nil }
            end += 1
        }
        guard end < line.count, end > start else { return nil }
        return String(decoding: UnsafeRawBufferPointer(rebasing: line[start..<end]), as: UTF8.self)
    }

    private static func fastType(_ line: UnsafeRawBufferPointer) -> String? {
        guard hasPrefix(line, typePrefix) else { return nil }
        return simpleString(line, from: typePrefix.count)
    }

    private static func fastToolCompleteId(_ line: UnsafeRawBufferPointer) -> String? {
        guard hasPrefix(line, toolCompletePrefix) else { return nil }
        return simpleString(line, from: toolCompletePrefix.count)
    }

    /// Top-level keys are ordered `type, data, [agentId], id, timestamp, parentId`, so the last
    /// `"timestamp":"` occurrence is the event's own timestamp, not one nested inside `data`.
    static func tailTimestamp(_ line: UnsafeRawBufferPointer) -> Date? {
        guard let keyStart = lastIndex(of: timestampKey, in: line) else { return nil }
        let valueStart = keyStart + timestampKey.count
        var end = valueStart
        while end < line.count, line[end] != 0x22 { end += 1 }
        guard end < line.count, end > valueStart else { return nil }
        return Timestamp.parse(UnsafeRawBufferPointer(rebasing: line[valueStart..<end]))
    }

    private static func hasTopLevelAgentId(_ line: UnsafeRawBufferPointer) -> Bool {
        guard let timestampStart = lastIndex(of: timestampKey, in: line) else { return false }
        return lastIndex(of: topLevelAgentIdKey, in: line, before: timestampStart,
                         notBefore: max(0, timestampStart - 200)) != nil
    }

    private static func lastIndex(
        of needle: [UInt8], in haystack: UnsafeRawBufferPointer, before upperBound: Int? = nil, notBefore lowerBound: Int = 0
    ) -> Int? {
        let needleCount = needle.count
        var index = (upperBound ?? haystack.count) - needleCount
        while index >= lowerBound {
            if haystack[index] == needle[0] {
                var matches = true
                for offset in 1..<needleCount where haystack[index + offset] != needle[offset] {
                    matches = false
                    break
                }
                if matches { return index }
            }
            index -= 1
        }
        return nil
    }

    private static func contains(_ haystack: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
        guard let base = haystack.baseAddress, haystack.count >= needle.count else { return false }
        return needle.withUnsafeBytes { needleBytes in
            memmem(base, haystack.count, needleBytes.baseAddress, needleBytes.count) != nil
        }
    }
}
