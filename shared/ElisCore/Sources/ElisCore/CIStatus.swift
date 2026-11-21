import Foundation

/// CIRunState groups a GitHub Actions run's `status` and `conclusion`.
public enum CIRunState: String, Codable, Sendable {
    case running, failed, passed, skipped

    public init(status: String, conclusion: String) {
        switch status.lowercased() {
        case "completed":
            switch conclusion.lowercased() {
            case "success", "neutral": self = .passed
            case "skipped": self = .skipped
            default: self = .failed
            }
        default: self = .running
        }
    }
}

/// CIRun is the latest run of one workflow on the branch's newest pushed commit.
public struct CIRun: Codable, Equatable, Sendable {
    public var workflow: String
    public var state: CIRunState
    public var url: String

    public init(workflow: String, state: CIRunState, url: String) {
        self.workflow = workflow
        self.state = state
        self.url = url
    }
}

/// CIPullRequest is the branch's open PR with the logins of its latest approving and change-requesting reviews.
public struct CIPullRequest: Codable, Equatable, Sendable {
    public var number: Int
    public var title: String
    public var url: String
    public var approved: [String]
    public var changesRequested: [String]

    public init(number: Int, title: String, url: String, approved: [String] = [], changesRequested: [String] = []) {
        self.number = number
        self.title = title
        self.url = url
        self.approved = approved
        self.changesRequested = changesRequested
    }
}

/// CIStatus is what the sidebar's CI line, its panel and the `ci` read-back show for a session's repository.
public struct CIStatus: Codable, Equatable, Sendable {
    public var branch: String
    /// sha is the commit the runs belong to, empty when there are none.
    public var sha: String
    public var pr: CIPullRequest?
    public var runs: [CIRun]

    public init(branch: String, sha: String, pr: CIPullRequest? = nil, runs: [CIRun] = []) {
        self.branch = branch
        self.sha = sha
        self.pr = pr
        self.runs = runs
    }

    public var isEmpty: Bool { pr == nil && counted.isEmpty }

    public var anyRunning: Bool { runs.contains { $0.state == .running } }

    private var counted: [CIRun] { runs.filter { $0.state != .skipped } }

    /// spans is the sidebar line: the PR with its review counts, then the runs failed → running → passed.
    public var spans: [SessionInfoSpan] {
        var spans: [SessionInfoSpan] = []
        if let pr {
            spans.append(SessionInfoSpan(text: "#\(pr.number)", bold: true))
            if !pr.approved.isEmpty { spans.append(SessionInfoSpan(text: " 👍\(pr.approved.count)")) }
            if !pr.changesRequested.isEmpty { spans.append(SessionInfoSpan(text: " 👎\(pr.changesRequested.count)")) }
        }
        let runs = runSpans
        if !spans.isEmpty, !runs.isEmpty { spans.append(SessionInfoSpan(text: " · ", dim: true)) }
        return spans + runs
    }

    private var runSpans: [SessionInfoSpan] {
        let counted = counted
        if counted.count == 1, let run = counted.first { return [Self.span(run.state, run.workflow)] }
        let groups: [(CIRunState, [CIRun])] = [.failed, .running, .passed].map { state in (state, counted.filter { $0.state == state }) }
            .filter { !$0.1.isEmpty }
        if groups.count == 1, let (state, runs) = groups.first { return [Self.span(state, "\(runs.count) \(state.rawValue)")] }
        var spans: [SessionInfoSpan] = []
        for (state, runs) in groups {
            if !spans.isEmpty { spans.append(SessionInfoSpan(text: "  ")) }
            let label = state == .failed && runs.count == 1 ? runs[0].workflow : "\(runs.count)"
            spans.append(Self.span(state, label))
        }
        return spans
    }

    private static func span(_ state: CIRunState, _ label: String) -> SessionInfoSpan {
        switch state {
        case .failed: SessionInfoSpan(text: "✗ \(label)", color: .red)
        case .running: SessionInfoSpan(text: "◷ \(label)", color: .yellow)
        case .passed: SessionInfoSpan(text: "✓ \(label)", color: .green)
        case .skipped: SessionInfoSpan(text: label, dim: true)
        }
    }
}
