import Foundation
import Testing
@testable import ElisCore

struct CIStatusTests {
    private func run(_ name: String, _ state: CIRunState) -> CIRun { CIRun(workflow: name, state: state, url: "u/\(name)") }

    private func line(_ runs: [CIRun], pr: CIPullRequest? = nil) -> String {
        CIStatus(branch: "b", sha: "s", pr: pr, runs: runs).spans.map(\.text).joined()
    }

    @Test func statesGroupGitHubValues() {
        #expect(CIRunState(status: "queued", conclusion: "") == .running)
        #expect(CIRunState(status: "in_progress", conclusion: "") == .running)
        #expect(CIRunState(status: "waiting", conclusion: "") == .running)
        #expect(CIRunState(status: "completed", conclusion: "success") == .passed)
        #expect(CIRunState(status: "completed", conclusion: "neutral") == .passed)
        #expect(CIRunState(status: "completed", conclusion: "skipped") == .skipped)
        for conclusion in ["failure", "timed_out", "cancelled", "action_required", "startup_failure", "stale"] {
            #expect(CIRunState(status: "completed", conclusion: conclusion) == .failed)
        }
    }

    @Test func oneRunShowsItsName() {
        #expect(line([run("build", .running)]) == "◷ build")
        #expect(line([run("build", .failed), run("lint", .skipped)]) == "✗ build")
    }

    @Test func oneGroupShowsItsCount() {
        #expect(line([run("a", .passed), run("b", .passed), run("c", .passed)]) == "✓ 3 passed")
        #expect(line([run("a", .running), run("b", .running)]) == "◷ 2 running")
        #expect(line([run("a", .failed), run("b", .failed)]) == "✗ 2 failed")
    }

    @Test func mixedGroupsCountFailedRunningPassed() {
        let runs = [run("p1", .passed), run("f1", .failed), run("r1", .running), run("f2", .failed), run("p2", .passed)]
        #expect(line(runs) == "✗ 2  ◷ 1  ✓ 2")
        #expect(line([run("build", .failed), run("r", .running), run("p1", .passed), run("p2", .passed)]) == "✗ build  ◷ 1  ✓ 2")
    }

    @Test func openPullRequestLeadsWithReviews() {
        let pr = CIPullRequest(number: 56, title: "t", url: "u", approved: ["a"], changesRequested: [])
        #expect(line([run("build", .failed), run("r", .running), run("p1", .passed), run("p2", .passed)], pr: pr)
                    == "#56 👍1 · ✗ build  ◷ 1  ✓ 2")
        #expect(line([run("build", .passed)], pr: CIPullRequest(number: 61, title: "t", url: "u", changesRequested: ["c"]))
                    == "#61 👎1 · ✓ build")
        #expect(line([], pr: CIPullRequest(number: 62, title: "t", url: "u", approved: ["a", "b"])) == "#62 👍2")
    }

    @Test func colorsFollowTheGroup() {
        let spans = CIStatus(branch: "b", sha: "s", runs: [run("f", .failed), run("r", .running), run("p", .passed),
                                                           run("q", .passed)]).spans
        #expect(spans.compactMap(\.color) == [.red, .yellow, .green])
    }

    @Test func nothingToShowIsEmpty() {
        #expect(CIStatus(branch: "b", sha: "").isEmpty)
        #expect(CIStatus(branch: "b", sha: "s", runs: [run("x", .skipped)]).isEmpty)
        #expect(!CIStatus(branch: "b", sha: "", pr: CIPullRequest(number: 1, title: "", url: "")).isEmpty)
    }
}
