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
        #expect(!seen.contains("--repo"))

        _ = CIProbe.runs(CIRepo(root: "/r", branch: "feature/x", pushRepo: "github.com/o/r")) { arguments, _ in
            seen = arguments
            return Data("[]".utf8)
        }
        #expect(seen.suffix(2) == ["--repo", "github.com/o/r"])
    }

    @Test(arguments: [
        ("https://github.com/NaikSoftware/elis.git", "github.com/NaikSoftware/elis"),
        ("https://user@ghe.example.com/o/r", "ghe.example.com/o/r"),
        ("git@github.com:o/r.git", "github.com/o/r"),
        ("ssh://git@github.com/o/r.git", "github.com/o/r"),
        ("ssh://git@github.com:22/o/r", "github.com/o/r"),
    ])
    func githubRepoReadsEveryURLForm(url: String, expected: String) {
        #expect(CIRepo.githubRepo(url) == expected)
    }

    @Test func githubRepoIsNilForAnUnparseableURL() {
        #expect(CIRepo.githubRepo("/srv/git/r.git") == nil)
        #expect(CIRepo.githubRepo("file:///srv/git/o/r") == nil)
        #expect(CIRepo.githubRepo("https://github.com/o") == nil)
    }

    private func checkout(config: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ci-remote-\(UUID().uuidString)")
        let gitDir = root.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try config.write(to: gitDir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        return root
    }

    @Test func locateFollowsGitsPushRemoteOrder() throws {
        let remotes = """
        [remote "origin"]
        \turl = https://github.com/me/fork.git
        [remote "upstream"]
        \turl = https://github.com/them/base.git
        \tgh-resolved = base
        [Remote "push"]
        \turl = git@github.com:me/push.git
        [remote "track"]
        \turl = git@github.com:me/track.git

        """
        let cases: [(String, String?)] = [
            ("", "github.com/me/fork"),
            ("[branch \"main\"]\n\tremote = track\n", "github.com/me/track"),
            ("[branch \"main\"]\n\tremote = track\n[remote]\n\tpushDefault = push\n", "github.com/me/push"),
            ("[remote]\n\tpushDefault = push\n[branch \"main\"]\n\tremote = track\n\tpushRemote = upstream\n", "github.com/them/base"),
            ("[branch \"main\"]\n\tremote = missing\n", nil),
        ]
        for (extra, expected) in cases {
            let root = try checkout(config: remotes + extra)
            defer { try? FileManager.default.removeItem(at: root) }
            #expect(CIRepo.locate(cwd: root.path)?.pushRepo == expected, "\(extra)")
        }
    }

    @Test func aWorktreeReadsTheCommonDirsConfig() throws {
        let main = try checkout(config: "[remote \"origin\"]\n\turl = git@github.com:me/fork.git\n")
        defer { try? FileManager.default.removeItem(at: main) }
        let gitDir = main.appendingPathComponent(".git/worktrees/wt")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try "ref: refs/heads/feature\n".write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "../..\n".write(to: gitDir.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        let worktree = main.appendingPathComponent("wt")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: \(gitDir.path)\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        #expect(CIRepo.locate(cwd: worktree.path) == CIRepo(root: worktree.path, branch: "feature", pushRepo: "github.com/me/fork"))
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

    /// ghResult runs the real runner against a fake `gh` script on a plain thread, as a blocking call must.
    private func ghResult(_ script: String, timeout: TimeInterval) async throws -> (Data?, TimeInterval) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ci-gh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let gh = dir.appendingPathComponent("gh")
        try "#!/bin/sh\n\(script)\n".write(to: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)
        let run = CIProbe.gh(environment: ["PATH": "\(dir.path):/usr/bin:/bin"], timeout: timeout)
        let directory = dir.path
        return await withCheckedContinuation { continuation in
            Thread {
                let started = Date()
                let data = run(["run", "list"], directory)
                continuation.resume(returning: (data, Date().timeIntervalSince(started)))
            }.start()
        }
    }

    @Test func theRunnerReturnsWhatGhPrintsAndNothingOnAFailure() async throws {
        let (printed, _) = try await ghResult(#"echo "[$1]""#, timeout: 10)
        #expect(printed.map { String(decoding: $0, as: UTF8.self) } == "[run]\n")
        let (failed, _) = try await ghResult("echo partial; exit 1", timeout: 10)
        #expect(failed == nil)
    }

    @Test func aGhWhoseChildHoldsThePipeIsAbandonedAtTheTimeout() async throws {
        let (data, elapsed) = try await ghResult("sleep 20", timeout: 0.5)
        #expect(data == nil)
        #expect(elapsed < 10)
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
