import Foundation
import Testing
@testable import ElisCore

@MainActor
struct CIPollerTests {
    final class Fake: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        var runs: String? = #"[{"workflowName":"build","status":"in_progress","conclusion":"","headSha":"s","url":"u"}]"#
        var pr: String?

        var calls: [String] { lock.withLock { _calls } }

        var runner: CIProbe.Runner {
            { [self] arguments, directory in
                lock.withLock {
                    _calls.append("\(arguments[0]) \(directory)")
                    return (arguments[0] == "run" ? runs : pr).map { Data($0.utf8) }
                }
            }
        }
    }

    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1000)
    }

    private let fake = Fake()
    private let clock = Clock()

    private func poller(_ sessions: [Session], include: @escaping @MainActor (Session) -> Bool = { _ in true },
                        into box: Box) -> CIPoller {
        let clock = clock
        let tracker = CITracker(runner: fake.runner, now: { clock.now },
                                locate: { cwd in cwd.hasPrefix("/repo") ? CIRepo(root: "/repo", branch: "main") : nil })
        return CIPoller(sessions: { sessions }, include: include, apply: { box.applied[$0.id] = .some($1) }, tracker: tracker)
    }

    @MainActor final class Box { var applied: [UUID: CIStatus?] = [:] }

    @Test func sessionsInOneRepositoryShareOneFetch() async {
        let a = Session(initialCwd: "/repo"), b = Session(initialCwd: "/repo/sub")
        let box = Box()
        await poller([a, b], into: box).tick()
        #expect(fake.calls.filter { $0.hasPrefix("run") } == ["run /repo"])
        let status = box.applied[a.id] ?? nil
        #expect(status?.runs.map(\.workflow) == ["build"])
        #expect((box.applied[b.id] ?? nil) == status)
    }

    @Test func runningRefetchesAfterThirtySecondsSettledAfterThree() async {
        let session = Session(initialCwd: "/repo")
        let box = Box()
        let poller = poller([session], into: box)
        await poller.tick()
        clock.now += 29
        await poller.tick()
        #expect(fake.calls.filter { $0.hasPrefix("run") }.count == 1)
        clock.now += 1
        fake.runs = #"[{"workflowName":"build","status":"completed","conclusion":"success","headSha":"s","url":"u"}]"#
        await poller.tick()
        #expect(fake.calls.filter { $0.hasPrefix("run") }.count == 2)
        clock.now += 179
        await poller.tick()
        #expect(fake.calls.filter { $0.hasPrefix("run") }.count == 2)
        clock.now += 1
        await poller.tick()
        #expect(fake.calls.filter { $0.hasPrefix("run") }.count == 3)
    }

    @Test func pullRequestIsAskedEveryTwoMinutes() async {
        let session = Session(initialCwd: "/repo")
        let box = Box()
        let poller = poller([session], into: box)
        await poller.tick()
        clock.now += 119
        await poller.tick()
        #expect(fake.calls.filter { $0.hasPrefix("pr") }.count == 1)
        clock.now += 1
        await poller.tick()
        #expect(fake.calls.filter { $0.hasPrefix("pr") }.count == 2)
    }

    @Test func aFailedRefreshClearsTheLine() async {
        let session = Session(initialCwd: "/repo")
        let box = Box()
        let poller = poller([session], into: box)
        await poller.tick()
        #expect((box.applied[session.id] ?? nil) != nil)
        fake.runs = nil
        clock.now += 30
        await poller.tick()
        #expect(box.applied[session.id] == .some(nil))
    }

    @Test func noRunsAndNoPullRequestShowNothing() async {
        fake.runs = "[]"
        let session = Session(initialCwd: "/repo")
        let box = Box()
        await poller([session], into: box).tick()
        #expect(box.applied[session.id] == .some(nil))
    }

    @Test func leavingTheRepositoryOrBeingExcludedClears() async {
        let inside = Session(initialCwd: "/repo"), outside = Session(initialCwd: "/tmp"), hidden = Session(initialCwd: "/repo")
        let box = Box()
        await poller([inside, outside, hidden], include: { $0.id != hidden.id }, into: box).tick()
        #expect((box.applied[inside.id] ?? nil) != nil)
        #expect(box.applied[outside.id] == .some(nil))
        #expect(box.applied[hidden.id] == .some(nil))
    }

    @Test func thePaneAgentsCwdWinsOverTheShellCwd() async {
        let session = Session(initialCwd: "/tmp")
        session.paneAgentCwd[.left] = "/repo/wt"
        let box = Box()
        await poller([session], into: box).tick()
        #expect(fake.calls.filter { $0.hasPrefix("run") } == ["run /repo"])
        #expect((box.applied[session.id] ?? nil) != nil)
    }

    @Test func remoteRowsAreNotPolled() async {
        let remote = Session(initialCwd: "/repo", remoteHost: "other-mac")
        let box = Box()
        await poller([remote], into: box).tick()
        #expect(fake.calls.isEmpty)
        #expect(box.applied[remote.id] == nil)
    }
}
