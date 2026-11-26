import Foundation

public enum SessionProgressError: Error, Equatable, CustomStringConvertible {
    case invalid

    public var description: String { "invalid progress" }
}

/// What set a session's progress: the control API, or OSC 9;4 from the terminal.
public enum ProgressSource: String, Sendable, Codable {
    case control, terminal
}

public enum TerminalProgressUpdate: Sendable, Equatable {
    case clear
    case set(SessionProgress)
}

public enum SessionProgress: Sendable, Equatable, Codable {
    case steps(done: Int, total: Int)
    case percent(Int)
    case indeterminate

    static let maxSteps = 10_000

    public var fraction: Double? {
        switch self {
        case let .steps(done, total): Double(done) / Double(total)
        case let .percent(value): Double(value) / 100
        case .indeterminate: nil
        }
    }

    public var label: String {
        switch self {
        case let .steps(done, total): "\(done)/\(total)"
        case let .percent(value): "\(value)%"
        case .indeterminate: "indeterminate"
        }
    }

    /// parse reads `3/7`, `40%`, `indeterminate`, or `clear` (nil).
    public static func parse(_ text: String) throws(SessionProgressError) -> SessionProgress? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch text {
        case "clear": return nil
        case "indeterminate": return .indeterminate
        default: break
        }
        if text.hasSuffix("%"), let value = Int(text.dropLast()), (0...100).contains(value) {
            return .percent(value)
        }
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count == 2, let done = Int(parts[0]), let total = Int(parts[1]),
           (1...maxSteps).contains(total), (0...total).contains(done) {
            return .steps(done: done, total: total)
        }
        throw .invalid
    }

    /// terminal maps ConEmu OSC 9;4 state and progress; nil for an unknown state.
    public static func terminal(state: Int, progress: Int) -> TerminalProgressUpdate? {
        switch state {
        case 0: .clear
        case 1, 2, 4: .set((0...100).contains(progress) ? .percent(progress) : .indeterminate)
        case 3: .set(.indeterminate)
        default: nil
        }
    }

    /// conEmu parses an OSC 9 body such as `4;1;40`; a missing or empty progress counts as -1.
    public static func conEmu(_ body: String) -> TerminalProgressUpdate? {
        let fields = body.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count >= 2, fields[0] == "4", let state = Int(fields[1]) else { return nil }
        let progress = fields.count > 2 ? Int(fields[2]) ?? -1 : -1
        return terminal(state: state, progress: progress)
    }

    private enum CodingKeys: String, CodingKey {
        case done, total, percent, indeterminate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let percent = try container.decodeIfPresent(Int.self, forKey: .percent) {
            self = .percent(percent)
        } else if try container.decodeIfPresent(Bool.self, forKey: .indeterminate) == true {
            self = .indeterminate
        } else {
            self = .steps(done: try container.decode(Int.self, forKey: .done),
                          total: try container.decode(Int.self, forKey: .total))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .steps(done, total):
            try container.encode(done, forKey: .done)
            try container.encode(total, forKey: .total)
        case let .percent(value): try container.encode(value, forKey: .percent)
        case .indeterminate: try container.encode(true, forKey: .indeterminate)
        }
    }
}
