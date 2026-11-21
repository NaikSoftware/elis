import Foundation

public struct AssistantEntry: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case user, assistant, sent, reply, error }

    public let id: UUID
    public let kind: Kind
    /// Session ids.
    public let from: String?
    public let to: [String]?
    public let text: String
    public let ts: Double
}

public enum AssistantMark: String, Codable, Sendable {
    case waiting, replied
    case notDelivered = "not-delivered"
}

/// AssistantChat is the assistant's transcript: the last `limit` entries, per-session delivery marks and an unread
/// count, persisted as JSONL when a file is given.
@MainActor
public final class AssistantChat {
    public static let shared = AssistantChat()

    static let limit = 500
    static let rewriteAbove = 600

    public private(set) var unread = 0
    public private(set) var marks: [String: AssistantMark] = [:]
    /// running is true while an input written to the provider still awaits its turn's end.
    public var running: Bool { pending > 0 }
    public var provider: SessionLauncher? {
        didSet { save(provider.map { Data($0.rawValue.utf8) }, as: "provider") }
    }
    /// resume is each provider's conversation id, so a restarted provider continues its own conversation.
    public var resume: [SessionLauncher: String] = [:] {
        didSet { save(try? JSONEncoder().encode(Dictionary(uniqueKeysWithValues: resume.map { ($0.key.rawValue, $0.value) })), as: "resume") }
    }

    private var pending = 0
    private var all: [AssistantEntry] = []
    private var fileLines = 0
    private let file: URL?

    public init(file: URL? = nil) {
        self.file = file
        guard let file else { return }
        if let text = try? String(contentsOf: file, encoding: .utf8) {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            fileLines = lines.count
            let decoder = JSONDecoder()
            all = Array(lines.compactMap { try? decoder.decode(AssistantEntry.self, from: Data($0.utf8)) }.suffix(Self.limit))
        }
        if let raw = try? String(contentsOf: file.appendingPathExtension("provider"), encoding: .utf8) {
            provider = SessionLauncher(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let data = try? Data(contentsOf: file.appendingPathExtension("resume")),
           let raw = try? JSONDecoder().decode([String: String].self, from: data) {
            resume = Dictionary(uniqueKeysWithValues: raw.compactMap { key, id in SessionLauncher(rawValue: key).map { ($0, id) } })
        }
    }

    @discardableResult
    public func append(_ kind: AssistantEntry.Kind, text: String, from: String? = nil, to: [String]? = nil, now: Double)
        -> AssistantEntry {
        let entry = AssistantEntry(id: UUID(), kind: kind, from: from, to: to, text: text, ts: now)
        all.append(entry)
        if all.count > Self.limit { all.removeFirst(all.count - Self.limit) }
        switch kind {
        case .user: marks = [:]
        case .sent: to?.forEach { marks[$0] = .waiting }
        case .reply:
            if let from { marks[from] = .replied }
            unread += 1
        case .assistant, .error: break
        }
        persist(entry)
        return entry
    }

    public func entries(last: Int?) -> [AssistantEntry] {
        guard let last else { return all }
        return Array(all.suffix(max(0, last)))
    }

    public func inputQueued() { pending += 1 }

    public func turnEnded() { pending = max(0, pending - 1) }

    /// providerFailed records why no provider could run, or why it died, and drops every queued input.
    public func providerFailed(_ message: String, now: Double) {
        append(.error, text: message, now: now)
        pending = 0
    }

    public func markSeen() { unread = 0 }

    public func markSkipped(_ sessionIDs: [String]) { sessionIDs.forEach { marks[$0] = .notDelivered } }

    private func save(_ data: Data?, as pathExtension: String) {
        guard let file, let data else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file.appendingPathExtension(pathExtension), options: .atomic)
    }

    // Save errors are dropped: a chat that cannot be written stays usable in memory.
    private func persist(_ entry: AssistantEntry) {
        guard let file else { return }
        let encoder = JSONEncoder()
        fileLines += 1
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileLines > Self.rewriteAbove {
            let lines = all.compactMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) + "\n" }
            try? lines.joined().write(to: file, atomically: true, encoding: .utf8)
            fileLines = lines.count
        } else if let data = try? encoder.encode(entry) {
            let line = data + Data("\n".utf8)
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: file)
            }
        }
    }
}
