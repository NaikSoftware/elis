import Foundation

/// CITracker answers each cwd's CI status with one fetch per (repository, branch), shared by every cwd in it, and
/// refetches only what is due. It blocks on the filesystem and on `gh`, so it runs off the main actor; the Mac's
/// `CIPoller` and the Linux bridge's `elis_ci_statuses` drive it, one call at a time.
public final class CITracker: @unchecked Sendable {
    static let runningInterval: TimeInterval = 30
    static let settledInterval: TimeInterval = 180
    static let pullRequestInterval: TimeInterval = 120

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

    private let runner: CIProbe.Runner
    private let now: @Sendable () -> Date
    private let locate: @Sendable (String) -> CIRepo?
    private let lock = NSLock()
    private var entries: [CIRepo: Entry] = [:]

    public init(runner: @escaping CIProbe.Runner = CIProbe.gh(), now: @escaping @Sendable () -> Date = Date.init,
                locate: @escaping @Sendable (String) -> CIRepo? = CIRepo.locate) {
        self.runner = runner
        self.now = now
        self.locate = locate
    }

    /// statuses gives each cwd's status, nil outside git, with nothing to show, or after a failed fetch; a
    /// repository no cwd names any more is forgotten.
    public func statuses(cwds: [String]) -> [CIStatus?] {
        let repos = cwds.map(locate)
        let present = Set(repos.compactMap { $0 })
        let started = now()
        let due = lock.withLock {
            entries = entries.filter { present.contains($0.key) }
            return present.compactMap { repo -> (CIRepo, Bool, Bool)? in
                let entry = entries[repo] ?? Entry()
                let runs = entry.runsDue <= started, pullRequest = entry.pullRequestDue <= started
                return runs || pullRequest ? (repo, runs, pullRequest) : nil
            }
        }
        let runner = runner
        let results = NSLock()
        nonisolated(unsafe) var fetched: [(CIRepo, Fetched<(sha: String, runs: [CIRun])?>, Fetched<CIPullRequest?>)] = []
        DispatchQueue.concurrentPerform(iterations: due.count) { index in
            let (repo, runs, pullRequest) = due[index]
            let result = (repo, runs ? Fetched.value(CIProbe.runs(repo, run: runner)) : .skipped,
                          pullRequest ? Fetched.value(CIProbe.pullRequest(repo, run: runner)) : .skipped)
            results.withLock { fetched.append(result) }
        }
        let finished = now()
        return lock.withLock {
            for (repo, runs, pullRequest) in fetched {
                var entry = entries[repo] ?? Entry()
                if case .value(let value) = runs {
                    entry.runs = value
                    let running = value?.runs.contains { $0.state == .running } ?? false
                    entry.runsDue = finished + (running ? Self.runningInterval : Self.settledInterval)
                }
                if case .value(let value) = pullRequest {
                    entry.pr = value
                    entry.pullRequestDue = finished + Self.pullRequestInterval
                }
                entries[repo] = entry
            }
            return repos.map { repo in
                repo.flatMap { repo in
                    entries[repo].flatMap { entry in
                        entry.runs.map { CIStatus(branch: repo.branch, sha: $0.sha, pr: entry.pr, runs: $0.runs) }
                    }
                }.flatMap { $0.isEmpty ? nil : $0 }
            }
        }
    }
}

/// CIPoller keeps each local session's `ci` current through a `CITracker`. A session it may not poll, or one
/// outside git, is cleared, so a hidden line never comes back stale.
@MainActor
public final class CIPoller {
    static let tickInterval: Duration = .seconds(5)

    private let sessions: @MainActor () -> [Session]
    private let include: @MainActor (Session) -> Bool
    private let apply: @MainActor (Session, CIStatus?) -> Void
    private let tracker: CITracker
    private var loop: Task<Void, Never>?

    /// `sessions` lists every candidate; remote-origin rows are skipped here, and `include` false clears one.
    public init(sessions: @escaping @MainActor () -> [Session], include: @escaping @MainActor (Session) -> Bool = { _ in true },
                apply: @escaping @MainActor (Session, CIStatus?) -> Void, tracker: CITracker = CITracker()) {
        self.sessions = sessions
        self.include = include
        self.apply = apply
        self.tracker = tracker
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
        let tracker = tracker
        let cwds = candidates.map(\.workingCwd)
        // the tracker blocks for up to gh's timeout, so it runs on a dispatch thread, never on the cooperative pool
        let statuses = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: tracker.statuses(cwds: cwds)) }
        }
        for (session, status) in zip(candidates, statuses) { apply(session, status) }
    }
}
