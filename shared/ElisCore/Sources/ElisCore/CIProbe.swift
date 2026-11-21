import Foundation

/// CIRepo is a git checkout and its current branch, found by reading `.git` rather than spawning git.
public struct CIRepo: Hashable, Sendable {
    public let root: String
    public let branch: String

    public init(root: String, branch: String) {
        self.root = root
        self.branch = branch
    }

    /// locate walks up from `cwd` to the first `.git`, a directory or a worktree's `gitdir:` file. Nil outside
    /// git and on a detached HEAD, which has no branch to ask GitHub about.
    public static func locate(cwd: String) -> CIRepo? {
        guard cwd.hasPrefix("/") else { return nil }
        var dir = URL(fileURLWithPath: cwd).standardizedFileURL
        while true {
            let dotGit = dir.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                return isDirectory.boolValue ? repo(root: dir, gitDir: dotGit) : worktree(root: dir, file: dotGit)
            }
            let parent = dir.deletingLastPathComponent()
            guard parent.path != dir.path else { return nil }
            dir = parent
        }
    }

    private static func worktree(root: URL, file: URL) -> CIRepo? {
        guard let text = try? String(contentsOf: file, encoding: .utf8), text.hasPrefix("gitdir:") else { return nil }
        let path = text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        let gitDir = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        return repo(root: root, gitDir: gitDir.standardizedFileURL)
    }

    private static func repo(root: URL, gitDir: URL) -> CIRepo? {
        let prefix = "ref: refs/heads/"
        guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), head.hasPrefix(prefix) else { return nil }
        return CIRepo(root: root.path, branch: String(head.dropFirst(prefix.count)))
    }
}

/// CIProbe asks `gh` about a repository. Every failure reads as nothing to show, never as an error.
public enum CIProbe {
    /// Runner runs `gh ARGUMENTS` in a directory and gives its stdout, nil unless it exited 0.
    public typealias Runner = @Sendable (_ arguments: [String], _ directory: String) -> Data?

    /// runs is the latest run of each workflow on the newest commit the branch has runs for, which is its last
    /// push, so local unpushed commits keep the previous push's line. Nil when `gh` fails.
    public static func runs(_ repo: CIRepo, run: Runner) -> (sha: String, runs: [CIRun])? {
        let arguments = ["run", "list", "--branch", repo.branch, "--limit", "30",
                         "--json", "workflowName,status,conclusion,headSha,url"]
        guard let data = run(arguments, repo.root), let list = try? JSONDecoder().decode([RunJSON].self, from: data) else {
            return nil
        }
        guard let sha = list.first?.headSha else { return ("", []) }
        var seen = Set<String>()
        let runs = list.filter { $0.headSha == sha && seen.insert($0.workflowName).inserted }
            .map { CIRun(workflow: $0.workflowName, state: CIRunState(status: $0.status, conclusion: $0.conclusion), url: $0.url) }
        return (sha, runs)
    }

    /// pullRequest is the checkout's branch's OPEN PR; `gh` exits 1 for a branch without one.
    public static func pullRequest(_ repo: CIRepo, run: Runner) -> CIPullRequest? {
        guard let data = run(["pr", "view", "--json", "number,title,url,state,latestReviews"], repo.root),
              let pr = try? JSONDecoder().decode(PullRequestJSON.self, from: data), pr.state == "OPEN" else { return nil }
        let reviews = pr.latestReviews ?? []
        func logins(_ state: String) -> [String] { reviews.filter { $0.state == state }.compactMap { $0.author?.login } }
        return CIPullRequest(number: pr.number, title: pr.title, url: pr.url, approved: logins("APPROVED"),
                             changesRequested: logins("CHANGES_REQUESTED"))
    }

    /// gh runs the user's `gh` with the widened PATH a launchd-started app needs, killed after `timeout`.
    public static func gh(environment: [String: String] = ProcessInfo.processInfo.environment,
                          timeout: TimeInterval = 15) -> Runner {
        var environment = environment
        environment["PATH"] = CommandPath.widened(environment["PATH"], bundledCLIDirectory: nil)
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        environment["NO_COLOR"] = "1"
        let resolved = environment
        return { arguments, directory in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["gh"] + arguments
            process.environment = resolved
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let pid = process.processIdentifier
            let deadline = DispatchWorkItem { kill(pid, SIGKILL) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            deadline.cancel()
            return process.terminationStatus == 0 ? data : nil
        }
    }

    private struct RunJSON: Decodable {
        let workflowName: String
        let status: String
        let conclusion: String
        let headSha: String
        let url: String
    }

    private struct PullRequestJSON: Decodable {
        struct Review: Decodable {
            struct Author: Decodable { let login: String }
            let author: Author?
            let state: String
        }

        let number: Int
        let title: String
        let url: String
        let state: String
        let latestReviews: [Review]?
    }
}
