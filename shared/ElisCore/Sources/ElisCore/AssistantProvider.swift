import Foundation

/// How an assistant CLI accepts turns: one long-lived NDJSON process or one process per input.
public enum AssistantMode: Sendable, Equatable {
    case stream, perInput
}

/// How the host starts a provider: `environment` is added to the inherited one, and `preamble`
/// is prepended to the text of the first input encoded into a fresh conversation.
/// The host strips inherited `ELIS_*` and `CLAUDE*` variables from that environment, and gives a `.perInput`
/// process `/dev/null` as stdin.
public struct AssistantLaunch: Sendable, Equatable {
    public let argv: [String]
    public let mode: AssistantMode
    public let environment: [String: String]
    public let preamble: String?

    public init(argv: [String], mode: AssistantMode, environment: [String: String] = [:], preamble: String? = nil) {
        self.argv = argv
        self.mode = mode
        self.environment = environment
        self.preamble = preamble
    }
}

/// Argv builders for each assistant CLI; every one runs headless with no permission prompt.
public enum AssistantProvider {
    /// Launchers eligible for the assistant picker (drops plain `.terminal`).
    public static func choices(_ available: [SessionLauncher]) -> [SessionLauncher] {
        available.filter { $0 != .terminal }
    }

    /// Long-lived launch for `.stream` providers; `.perInput` providers return `argv: []` and use `turn`.
    public static func launch(_ p: SessionLauncher, prompt: String, resume: String?) -> AssistantLaunch {
        let resume = resume.flatMap { $0.isEmpty ? nil : $0 }
        switch p {
        case .claude:
            var argv = [
                "claude", "-p",
                "--input-format", "stream-json",
                "--output-format", "stream-json",
                "--verbose",
                "--permission-mode", "bypassPermissions",
            ]
            if !prompt.isEmpty { argv += ["--append-system-prompt", prompt] }
            if let resume { argv += ["--resume", resume] }
            return AssistantLaunch(argv: argv, mode: .stream)
        case .antigravity:
            // agy has no system-prompt flag, and -p would take the next flag as its prompt.
            var argv = [
                "agy",
                "--dangerously-skip-permissions",
                "--input-format", "stream-json",
                "--output-format", "stream-json",
            ]
            if let resume { argv += ["--conversation", resume] }
            let preamble = resume == nil && !prompt.isEmpty ? "\(prompt)\n\n" : nil
            return AssistantLaunch(argv: argv, mode: .stream, preamble: preamble)
        case .codex, .opencode:
            return AssistantLaunch(argv: [], mode: .perInput)
        case .terminal:
            return AssistantLaunch(argv: [], mode: .stream)
        }
    }

    /// Per-input command for `.perInput` providers; prepends `prompt` on the initial turn.
    /// `--` keeps an input such as `--help` from parsing as an option.
    public static func turn(_ p: SessionLauncher, input: String, prompt: String, resume: String?) -> [String] {
        let resume = resume.flatMap { $0.isEmpty ? nil : $0 }
        let text = resume == nil && !prompt.isEmpty ? "\(prompt)\n\n\(input)" : input
        switch p {
        case .codex:
            let flags = ["--json", "--dangerously-bypass-approvals-and-sandbox", "--skip-git-repo-check", "--"]
            if let resume { return ["codex", "exec", "resume"] + flags + [resume, text] }
            return ["codex", "exec"] + flags + [text]
        case .opencode:
            var argv = ["opencode", "run", "--format", "json", "--auto"]
            if let resume { argv += ["--session", resume] }
            return argv + ["--", text]
        case .terminal, .claude, .antigravity:
            return []
        }
    }
}
