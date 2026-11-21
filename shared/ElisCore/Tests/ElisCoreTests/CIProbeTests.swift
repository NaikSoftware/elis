import Foundation
import Testing
@testable import ElisCore

struct CIProbeTests {
    static let runsJSON = """
    [{"workflowName":"build","status":"in_progress","conclusion":"","headSha":"new","url":"r/3"},
     {"workflowName":"pages","status":"completed","conclusion":"success","headSha":"new","url":"r/2"},
     {"workflowName":"build","status":"completed","conclusion":"failure","headSha":"new","url":"r/1"},
     {"workflowName":"build","status":"completed","conclusion":"success","headSha":"old","url":"r/0"}]
    """

    static let prJSON = """
    {"number":56,"title":"refactor","url":"https://github.com/o/r/pull/56","state":"OPEN",
     "latestReviews":[{"author":{"login":"alice"},"state":"APPROVED"},{"author":{"login":"bob"},"state":"CHANGES_REQUESTED"},
                      {"author":{"login":"carol"},"state":"COMMENTED"}]}
    """

    private func runner(_ outputs: [String: String?]) -> CIProbe.Runner {
        { arguments, _ in outputs[arguments[0]].flatMap { $0 }.map { Data($0.utf8) } }
    }

    private let repo = CIRepo(root: "/r", branch: "feature/x")

    @Test func runsKeepTheNewestCommitsLatestRunPerWorkflow() throws {
        let result = try #require(CIProbe.runs(repo, run: runner(["run": Self.runsJSON])))
        #expect(result.sha == "new")
        #expect(result.runs == [CIRun(workflow: "build", state: .running, url: "r/3"),
                                CIRun(workflow: "pages", state: .passed, url: "r/2")])
    }

    @Test func runsAskForTheBranch() {
        nonisolated(unsafe) var seen: [String] = []
        _ = CIProbe.runs(repo) { arguments, directory in
            seen = arguments + [directory]
            return Data("[]".utf8)
        }
        #expect(seen.starts(with: ["run", "list", "--branch", "feature/x"]))
        #expect(seen.last == "/r")
    }

    @Test func noRunsIsEmptyAndAFailureIsNil() {
        #expect(CIProbe.runs(repo, run: runner(["run": "[]"]))?.runs == [])
        #expect(CIProbe.runs(repo, run: runner(["run": nil])) == nil)
        #expect(CIProbe.runs(repo, run: runner(["run": "not json"])) == nil)
    }

    @Test func openPullRequestCountsLatestReviews() throws {
        let pr = try #require(CIProbe.pullRequest(repo, run: runner(["pr": Self.prJSON])))
        #expect(pr.number == 56)
        #expect(pr.approved == ["alice"])
        #expect(pr.changesRequested == ["bob"])
    }

    @Test func mergedOrMissingPullRequestIsNil() {
        let merged = Self.prJSON.replacingOccurrences(of: "\"OPEN\"", with: "\"MERGED\"")
        #expect(CIProbe.pullRequest(repo, run: runner(["pr": merged])) == nil)
        #expect(CIProbe.pullRequest(repo, run: runner(["pr": nil])) == nil)
    }

    @Test func locateReadsBranchFromCheckoutAndWorktree() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ci-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let main = base.appendingPathComponent("main")
        let gitDir = main.appendingPathComponent(".git")
        let nested = main.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gitDir.appendingPathComponent("worktrees/wt"), withIntermediateDirectories: true)
        try "ref: refs/heads/master\n".write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        #expect(CIRepo.locate(cwd: nested.path) == CIRepo(root: main.path, branch: "master"))

        let worktree = base.appendingPathComponent("wt")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: \(gitDir.path)/worktrees/wt\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        try "ref: refs/heads/feature/ci\n".write(to: gitDir.appendingPathComponent("worktrees/wt/HEAD"), atomically: true, encoding: .utf8)
        #expect(CIRepo.locate(cwd: worktree.path) == CIRepo(root: worktree.path, branch: "feature/ci"))

        try "0123456789abcdef\n".write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        #expect(CIRepo.locate(cwd: main.path) == nil)
        #expect(CIRepo.locate(cwd: base.path) == nil)
        #expect(CIRepo.locate(cwd: "relative") == nil)
    }
}
