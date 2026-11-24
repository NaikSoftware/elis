import Dispatch
import Foundation

/// Pages of `<directory>/brain/<id>/.system_generated/logs/transcript_full.jsonl`, the Antigravity CLI's conversation log.
public final class AntigravityTranscript: @unchecked Sendable {
    private static let instances = Locked<[String: AntigravityTranscript]>([:])

    public static func instance(directory: String) -> AntigravityTranscript {
        instances.withLock { all in
            if let known = all[directory] { return known }
            let made = AntigravityTranscript(directory: directory)
            all[directory] = made
            return made
        }
    }

    let directory: String
    let cacheLimit: Int
    private let indexes = Locked<[(path: String, index: Locked<AntigravityTranscriptIndex>)]>([])
    private let scanCount = Locked(0)

    /// How many indexes were built from scratch.
    var scans: Int { scanCount.withLock { $0 } }

    public init(directory: String) {
        self.directory = directory
        self.cacheLimit = 8
    }

    init(directory: String, cacheLimit: Int) {
        self.directory = directory
        self.cacheLimit = cacheLimit
    }

    /// Blocking file reads; never on the main thread.
    public func page(_ request: ClaudeTranscriptRequest) -> Result<ClaudeTranscriptPage, ClaudeTranscriptError> {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard let id = SessionLauncher.plainSessionID(request.sessionID) else { return .failure(.notFound) }
        let path = transcriptPath(for: id)
        guard FileManager.default.fileExists(atPath: path) else {
            evict(path)
            return .failure(.notFound)
        }
        let built = index(for: path).withLock { index -> ClaudeTranscriptPage? in
            guard refresh(&index), let reader = AntigravityRowReader(index: index) else { return nil }
            return AntigravityPageBuilder(reader: reader).page(request, id: id)
        }
        guard let page = built else {
            evict(path)
            return .failure(.notFound)
        }
        return .success(page)
    }

    private func transcriptPath(for id: String) -> String {
        (directory as NSString).appendingPathComponent("brain/\(id)/.system_generated/logs/transcript_full.jsonl")
    }

    private func index(for path: String) -> Locked<AntigravityTranscriptIndex> {
        indexes.withLock { list in
            if let at = list.firstIndex(where: { $0.path == path }) {
                let entry = list.remove(at: at)
                list.append(entry)
                return entry.index
            }
            scanCount.withLock { $0 += 1 }
            let made = Locked(AntigravityTranscriptIndex(path: path))
            list.append((path, made))
            if list.count > cacheLimit { list.removeFirst() }
            return made
        }
    }

    private func evict(_ path: String) {
        indexes.withLock { list in
            list.removeAll { $0.path == path }
        }
    }

    /// Extends the index, rebuilding when the file shrank or changed its head; false when unreadable.
    private func refresh(_ index: inout AntigravityTranscriptIndex) -> Bool {
        if index.extend() { return true }
        scanCount.withLock { $0 += 1 }
        index = AntigravityTranscriptIndex(path: index.path)
        return index.extend()
    }
}

// MARK: - Index

private enum AntigravityRowKind {
    case userInput
    case plannerResponse
    case errorMessage
    case modelResult
    case ignored
}

private struct AntigravityRow {
    var offset: Int
    var length: Int
    var stepIndex: Int
    var kind: AntigravityRowKind
}

private final class AntigravityTranscriptIndex {
    private static let chunk = 1 << 20
    private static let prefixLength = 4096
    private static let hiddenTypes: Set<String> = [
        "SYSTEM_MESSAGE", "EPHEMERAL_MESSAGE", "CHECKPOINT", "CONVERSATION_HISTORY",
    ]

    let path: String
    /// Byte offset just past the last indexed `\n`-terminated line.
    private(set) var end = 0
    private(set) var rows: [AntigravityRow] = []
    private(set) var meta = ControlTranscriptMeta()
    /// planner row index → (call index → result row index)
    private(set) var plannerResults: [Int: [Int: Int]] = [:]
    /// result row index → the planner row and call index it answers
    private(set) var closer: [Int: (plannerRow: Int, callIndex: Int)] = [:]
    /// Planner row still open for results (no later PLANNER_RESPONSE or USER_INPUT has ended its search).
    private(set) var openPlanner: (rowIndex: Int, nextCall: Int, totalCalls: Int)?

    private var prefix = Data()

    init(path: String) {
        self.path = path
    }

    func extend() -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), Int(fileSize) >= end else { return false }
        if !prefix.isEmpty {
            try? handle.seek(toOffset: 0)
            guard (try? handle.read(upToCount: prefix.count)) == prefix else { return false }
        }
        scan(handle)
        if prefix.count < Self.prefixLength, end > prefix.count {
            try? handle.seek(toOffset: 0)
            prefix = (try? handle.read(upToCount: min(Self.prefixLength, end))) ?? prefix
        }
        return true
    }

    func resultRow(forPlanner rowIndex: Int, call callIndex: Int) -> Int? {
        plannerResults[rowIndex]?[callIndex]
    }

    /// True while no later PLANNER_RESPONSE or USER_INPUT ended this planner's result search.
    func isPlannerOpen(_ rowIndex: Int) -> Bool {
        openPlanner?.rowIndex == rowIndex
    }

    private func scan(_ handle: FileHandle) {
        try? handle.seek(toOffset: UInt64(end))
        var buffer: [UInt8] = []
        var lineStart = end
        while let data = try? handle.read(upToCount: Self.chunk), !data.isEmpty {
            buffer.append(contentsOf: data)
            var from = 0
            while let newline = buffer[from...].firstIndex(of: 0x0A) {
                add(line: buffer[from..<newline], offset: lineStart)
                lineStart += newline - from + 1
                from = newline + 1
            }
            buffer.removeFirst(from)
        }
        end = lineStart
    }

    private func add(line: ArraySlice<UInt8>, offset: Int) {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
        else { return }
        let rowIndex = rows.count
        let type = object["type"] as? String ?? ""
        let source = object["source"] as? String ?? ""
        let stepIndex = object["step_index"] as? Int ?? rowIndex

        let kind: AntigravityRowKind
        switch type {
        case "USER_INPUT":
            openPlanner = nil
            kind = source == "USER_EXPLICIT" ? .userInput : .ignored
        case "PLANNER_RESPONSE":
            openPlanner = nil
            if source == "MODEL" {
                kind = .plannerResponse
                if let model = object["model"] as? String, !model.isEmpty {
                    meta.model = model
                }
                let calls = (object["tool_calls"] as? [[String: Any]])?.count ?? 0
                if calls > 0 {
                    openPlanner = (rowIndex, 0, calls)
                }
            } else {
                kind = .ignored
            }
        case "ERROR_MESSAGE":
            kind = .errorMessage
        case _ where Self.hiddenTypes.contains(type):
            kind = .ignored
        default:
            if source == "MODEL" {
                kind = .modelResult
                if var pending = openPlanner {
                    plannerResults[pending.rowIndex, default: [:]][pending.nextCall] = rowIndex
                    closer[rowIndex] = (pending.rowIndex, pending.nextCall)
                    pending.nextCall += 1
                    openPlanner = pending.nextCall < pending.totalCalls ? pending : nil
                }
            } else {
                kind = .ignored
            }
        }

        rows.append(AntigravityRow(offset: offset, length: line.count, stepIndex: stepIndex, kind: kind))
    }
}

// MARK: - Row Reader

private final class AntigravityRowReader {
    let index: AntigravityTranscriptIndex
    private let handle: FileHandle
    private var objects: [Int: [String: Any]] = [:]

    init?(index: AntigravityTranscriptIndex) {
        guard let handle = FileHandle(forReadingAtPath: index.path) else { return nil }
        self.index = index
        self.handle = handle
    }

    deinit { try? handle.close() }

    func object(_ rowIndex: Int) -> [String: Any]? {
        if let known = objects[rowIndex] { return known }
        let row = index.rows[rowIndex]
        guard (try? handle.seek(toOffset: UInt64(row.offset))) != nil,
              let data = try? handle.read(upToCount: row.length),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        objects[rowIndex] = object
        return object
    }
}

// MARK: - Page Builder

private final class AntigravityPageBuilder {
    private static let readOnlyTools: Set<String> = ["read_file", "view_file", "grep_search", "list_dir", "search_web"]
    private static let fileTools: Set<String> = ["read_file", "view_file", "edit_file", "write_file", "write_to_file"]

    private let reader: AntigravityRowReader
    private var index: AntigravityTranscriptIndex { reader.index }
    private let encoder = JSONEncoder()

    init(reader: AntigravityRowReader) {
        self.reader = reader
    }

    func page(_ request: ClaudeTranscriptRequest, id: String) -> ClaudeTranscriptPage {
        let budget = min(request.maxBytes, ClaudeTranscript.pageBudget)
        let size = index.end
        let reset = request.held.map { $0 != id } == true || request.after.map { $0 > size } == true
        var page = ClaudeTranscriptPage(transcript: id, size: size, start: size, next: size, reset: reset, meta: index.meta)
        if let after = request.after, !reset {
            (page.items, page.next) = forward(from: after, budget: budget)
            page.start = after
        } else {
            let before = reset ? nil : request.before
            page.items = backward(before: before ?? size + 1, budget: budget)
            page.start = page.items.first?.at ?? before ?? size
            page.next = before ?? size
        }
        return page
    }

    // MARK: - Walks

    private func forward(from after: Int, budget: Int) -> ([ControlTranscriptItem], Int) {
        var reemitted: [ControlTranscriptItem] = []
        var regular: [ControlTranscriptItem] = []
        var emittedToolIDs = Set<String>()
        var used = 1
        var next = index.end
        let startIndex = firstRow(atOrAfter: after)
        for rowIndex in startIndex..<index.rows.count {
            let hasItems = !reemitted.isEmpty || !regular.isEmpty
            if let closed = index.closer[rowIndex] {
                guard index.rows[closed.plannerRow].offset < after,
                      let tool = toolItem(plannerRow: closed.plannerRow, callIndex: closed.callIndex),
                      let toolID = tool.id, !emittedToolIDs.contains(toolID)
                else { continue }
                let cost = encodedSize(tool) + 1
                if hasItems, used + cost > budget {
                    next = index.rows[rowIndex].offset
                    break
                }
                used += cost
                reemitted.append(tool)
                emittedToolIDs.insert(toolID)
            } else {
                let made = items(of: rowIndex)
                guard !made.isEmpty else { continue }
                let cost = made.reduce(0) { $0 + encodedSize($1) + 1 }
                if hasItems, used + cost > budget {
                    next = index.rows[rowIndex].offset
                    break
                }
                used += cost
                regular.append(contentsOf: made)
            }
        }
        return (reemitted + regular, next)
    }

    private func backward(before: Int, budget: Int) -> [ControlTranscriptItem] {
        var items: [ControlTranscriptItem] = []
        var used = 1
        let limit = firstRow(atOrAfter: before)
        for rowIndex in (0..<limit).reversed() {
            let made = self.items(of: rowIndex)
            guard !made.isEmpty else { continue }
            let cost = made.reduce(0) { $0 + encodedSize($1) + 1 }
            if !items.isEmpty, used + cost > budget { break }
            used += cost
            items.insert(contentsOf: made, at: 0)
        }
        return items
    }

    private func firstRow(atOrAfter offset: Int) -> Int {
        var low = 0, high = index.rows.count
        while low < high {
            let mid = (low + high) / 2
            if index.rows[mid].offset < offset { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private func encodedSize(_ item: ControlTranscriptItem) -> Int {
        (try? encoder.encode(item).count) ?? 0
    }

    // MARK: - Items

    private func items(of rowIndex: Int) -> [ControlTranscriptItem] {
        let row = index.rows[rowIndex]
        switch row.kind {
        case .userInput:
            guard let object = reader.object(rowIndex) else { return [] }
            let raw = object["content"] as? String ?? ""
            let prompt = (ClaudeTranscriptItems.tag("USER_REQUEST", in: raw) ?? raw)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else { return [] }
            var item = ControlTranscriptItem(kind: "user", uuid: "\(row.stepIndex)", at: row.offset, time: object["created_at"] as? String)
            item.text = prompt
            item.promptSource = "typed"
            return [ClaudeTranscriptItems.capped(item)]

        case .plannerResponse:
            guard let object = reader.object(rowIndex) else { return [] }
            let step = row.stepIndex
            let time = object["created_at"] as? String
            var made: [ControlTranscriptItem] = []
            if let thinking = object["thinking"] as? String, !thinking.isEmpty {
                made.append(ClaudeTranscriptItems.capped(
                    ControlTranscriptItem(kind: "thinking", uuid: "\(step)#thinking", at: row.offset, time: time)))
            }
            if let content = object["content"] as? String, !content.isEmpty {
                var item = ControlTranscriptItem(kind: "text", uuid: "\(step)#text", at: row.offset, time: time)
                item.text = content
                made.append(ClaudeTranscriptItems.capped(item))
            }
            let calls = object["tool_calls"] as? [[String: Any]] ?? []
            for (k, call) in calls.enumerated() {
                made.append(buildToolItem(call, callIndex: k, plannerRow: rowIndex, time: time))
            }
            if let error = object["error"] as? String, !error.isEmpty {
                var item = ControlTranscriptItem(kind: "error", uuid: "\(step)#error", at: row.offset, time: time)
                item.text = error
                made.append(ClaudeTranscriptItems.capped(item))
            }
            return made

        case .errorMessage:
            guard let object = reader.object(rowIndex) else { return [] }
            var item = ControlTranscriptItem(kind: "error", uuid: "\(row.stepIndex)", at: row.offset, time: object["created_at"] as? String)
            let content = object["content"] as? String
            item.text = content.flatMap { $0.isEmpty ? nil : $0 } ?? (object["error"] as? String) ?? ""
            return [ClaudeTranscriptItems.capped(item)]

        case .modelResult, .ignored:
            return []
        }
    }

    private func toolItem(plannerRow: Int, callIndex: Int) -> ControlTranscriptItem? {
        guard let object = reader.object(plannerRow),
              let calls = object["tool_calls"] as? [[String: Any]],
              callIndex < calls.count
        else { return nil }
        return buildToolItem(calls[callIndex], callIndex: callIndex, plannerRow: plannerRow, time: object["created_at"] as? String)
    }

    private func buildToolItem(_ call: [String: Any], callIndex: Int, plannerRow: Int, time: String?) -> ControlTranscriptItem {
        let row = index.rows[plannerRow]
        let step = row.stepIndex
        let name = call["name"] as? String ?? ""
        let args = call["args"] as? [String: Any] ?? [:]
        var tool = ControlTranscriptItem(kind: "tool", uuid: "\(step)#tool\(callIndex)", at: row.offset, time: time)
        tool.id = "\(step).\(callIndex)"
        tool.name = name
        tool.arg = Self.shortArgument(name: name, args: args)
        if Self.fileTools.contains(name) { tool.file = Self.toolPath(name: name, args: args) }
        if Self.readOnlyTools.contains(name) { tool.readOnly = true }

        if let resultRowIndex = self.index.resultRow(forPlanner: plannerRow, call: callIndex),
           let result = reader.object(resultRowIndex) {
            let status = result["status"] as? String ?? ""
            let stripped = Self.stripResultHeaders(result["content"] as? String ?? "")
            let isError = status == "ERROR"
            let rawOutput = isError && stripped.isEmpty ? (result["error"] as? String ?? "") : stripped
            let (output, cut) = ClaudeTranscriptItems.clip(rawOutput, ClaudeTranscript.clipBytes)
            tool.output = output
            if cut { tool.clipped = true }
            if isError {
                tool.isError = true
                tool.mark = "error"
            } else if status == "RUNNING" {
                tool.mark = nil
            } else if name == "run_command" {
                let code = Self.parseExitCode(from: stripped)
                tool.exitCode = code
                tool.mark = code.flatMap { $0 != 0 ? "exit \($0)" : nil } ?? "ok"
            }
        } else if self.index.isPlannerOpen(plannerRow) {
            tool.running = true
            tool.mark = "running"
        } else {
            tool.mark = "interrupted"
        }
        return ClaudeTranscriptItems.capped(tool)
    }

    // MARK: - Formatting Helpers

    private static func nonEmpty(_ key: String, in args: [String: Any]) -> String? {
        (args[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func toolPath(name: String, args: [String: Any]) -> String? {
        switch name {
        case "view_file": return nonEmpty("AbsolutePath", in: args) ?? nonEmpty("Path", in: args)
        case "write_file", "write_to_file": return nonEmpty("Path", in: args) ?? nonEmpty("TargetFile", in: args)
        case "list_dir": return nonEmpty("DirectoryPath", in: args) ?? nonEmpty("Path", in: args)
        default: return nonEmpty("Path", in: args) ?? nonEmpty("AbsolutePath", in: args)
        }
    }

    private static func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    private static func shortArgument(name: String, args: [String: Any]) -> String? {
        switch name {
        case "run_command":
            return nonEmpty("toolSummary", in: args) ?? nonEmpty("CommandLine", in: args)
        case _ where fileTools.contains(name), "list_dir":
            return toolPath(name: name, args: args).map(lastComponent)
        case "grep_search":
            return nonEmpty("Query", in: args)
        case "search_web":
            return nonEmpty("query", in: args)
        default:
            return nil
        }
    }

    private static func stripResultHeaders(_ content: String) -> String {
        var rest = content[...]
        while rest.hasPrefix("Created At:") || rest.hasPrefix("Completed At:") {
            guard let nl = rest.firstIndex(of: "\n") else { return "" }
            rest = rest[rest.index(after: nl)...]
        }
        return String(rest)
    }

    private static func parseExitCode(from text: String) -> Int? {
        let prefix = "Command exited with code "
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.hasPrefix(prefix) else { continue }
            let after = line.dropFirst(prefix.count)
            var end = after.startIndex
            if end < after.endIndex, after[end] == "-" { end = after.index(after: end) }
            let digitsStart = end
            while end < after.endIndex, after[end].isASCII, after[end].isNumber {
                end = after.index(after: end)
            }
            if end > digitsStart, let code = Int(after[after.startIndex..<end]) {
                return code
            }
        }
        return nil
    }
}
