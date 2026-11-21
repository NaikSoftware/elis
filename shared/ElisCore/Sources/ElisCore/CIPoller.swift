import Foundation

/// CIPoller keeps each local session's `ci` current: one fetch per (repository, branch), shared by every
/// session in it. A session it may not poll, or one outside git, is cleared, so a hidden line never comes back
/// stale.
@MainActor
public final class CIPoller {
    static let runningInterval: TimeInterval = 30
    static let settledInterval: TimeInterval = 180
    static let pullRequestInterval: TimeInterval = 120
    static let tickInterval: Duration = .seconds(5)

    private struct Entry {
        var runs: (sha: String, runs: [CIRun])?
        var pr: CIPullRequest?
        var runsDue = Date.distantPast
        var pullRequestDue = Date.distantPast
    }

    private enum Fetched<Value: Sendable>: Sendable {
        case skipped
        case value(Value)
    }

    private let sessions: @MainActor () -> [Session]
    private let include: @MainActor (Session) -> Bool
    private let apply: @MainActor (Session, CIStatus?) -> Void
    private let runner: CIProbe.Runner
    private let now: () -> Date
    private let locate: @Sendable (String) -> CIRepo?
    private var entries: [CIRepo: Entry] = [:]
    private var loop: Task<Void, Never>?

    /// `sessions` lists every candidate; remote-origin rows are skipped here, and `include` false clears one.
    public init(sessions: @escaping @MainActor () -> [Session], include: @escaping @MainActor (Session) -> Bool = { _ in true },
                apply: @escaping @MainActor (Session, CIStatus?) -> Void, runner: @escaping CIProbe.Runner = CIProbe.gh(),
                now: @escaping () -> Date = Date.init, locate: @escaping @Sendable (String) -> CIRepo? = CIRepo.locate) {
        self.sessions = sessions
        self.include = include
        self.apply = apply
        self.runner = runner
        self.now = now
        self.locate = locate
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: Self.tickInterval)
            }
        }
    }

    /// offPool runs blocking filesystem and gh work on a dispatch thread, never on the cooperative pool.
    private nonisolated static func offPool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: work()) }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// tick fetches every repository that is due and applies each session's current status.
    public func tick() async {
        var candidates: [Session] = []
        for session in sessions() where session.remoteHost == nil && session.remotePresentation == nil {
            if include(session) { candidates.append(session) } else { apply(session, nil) }
        }
        let locate = locate
        let cwds = candidates.map(\.focusedCwd)
        let repos = await Self.offPool { cwds.map(locate) }
        var groups: [CIRepo: [Session]] = [:]
        for (session, repo) in zip(candidates, repos) {
            guard let repo else {
                apply(session, nil)
                continue
            }
            groups[repo, default: []].append(session)
        }
        entries = entries.filter { groups[$0.key] != nil }
        let started = now()
        let due = groups.keys.compactMap { repo -> (CIRepo, Bool, Bool)? in
            let entry = entries[repo] ?? Entry()
            let runs = entry.runsDue <= started, pullRequest = entry.pullRequestDue <= started
            return runs || pullRequest ? (repo, runs, pullRequest) : nil
        }
        let runner = runner
        let results = await Self.offPool {
            let lock = NSLock()
            nonisolated(unsafe) var results: [(CIRepo, Fetched<(sha: String, runs: [CIRun])?>, Fetched<CIPullRequest?>)] = []
            DispatchQueue.concurrentPerform(iterations: due.count) { index in
                let (repo, runs, pullRequest) = due[index]
                let result = (repo, runs ? Fetched.value(CIProbe.runs(repo, run: runner)) : .skipped,
                              pullRequest ? Fetched.value(CIProbe.pullRequest(repo, run: runner)) : .skipped)
                lock.withLock { results.append(result) }
            }
            return results
        }
        let finished = now()
        for (repo, runs, pullRequest) in results where groups[repo] != nil {
            var entry = entries[repo] ?? Entry()
            if case .value(let fetched) = runs {
                entry.runs = fetched
                let running = fetched?.runs.contains { $0.state == .running } ?? false
                entry.runsDue = finished + (running ? Self.runningInterval : Self.settledInterval)
            }
            if case .value(let fetched) = pullRequest {
                entry.pr = fetched
                entry.pullRequestDue = finished + Self.pullRequestInterval
            }
            entries[repo] = entry
        }
        for (repo, members) in groups {
            let status = entries[repo].flatMap { entry in
                entry.runs.map { CIStatus(branch: repo.branch, sha: $0.sha, pr: entry.pr, runs: $0.runs) }
            }
            members.forEach { apply($0, status?.isEmpty == false ? status : nil) }
        }
    }
}
