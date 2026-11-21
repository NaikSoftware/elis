import Foundation

/// How an assistant CLI accepts turns: one long-lived NDJSON process or one process per input.
public enum AssistantMode: Sendable, Equatable {
    case stream, perInput
}

/// Launch configuration for a streaming assistant process.
public struct AssistantLaunch: Sendable, Equatable {
    public let argv: [String]
    public let mode: AssistantMode

    public init(argv: [String], mode: AssistantMode) {
        self.argv = argv
        self.mode = mode
    }
}

/// Argv and environment builders for each assistant CLI supported by Elis.
public enum AssistantProvider {
    // Request-review + explicit command(elisctl) allow rule overrides any user auto/always-proceed setting.
    private static let antigravitySettings = #"{"agentMode":"","toolPermission":"request-review","permissions":{"allow":["command(elisctl)"]}}"#
    private static let opencodePermission = #"{"*":"deny","bash":{"*":"deny","elisctl *":"allow"}}"#

    /// Launchers eligible for the assistant picker (drops plain `.terminal`).
    public static func choices(_ available: [SessionLauncher]) -> [SessionLauncher] {
        available.filter { $0 != .terminal }
    }

    /// Long-lived launch command for `.stream` providers; `.perInput` providers return `argv: []`.
    public static func launch(_ p: SessionLauncher, prompt: String, resume: String?) -> AssistantLaunch {
        switch p {
        case .claude:
            var argv = [
                "claude", "-p",
                "--input-format", "stream-json",
                "--output-format", "stream-json",
                "--verbose",
                "--allowedTools", "Bash(elisctl:*)",
            ]
            if !prompt.isEmpty { argv += ["--append-system-prompt", prompt] }
            if let resume, !resume.isEmpty { argv += ["--resume", resume] }
            return AssistantLaunch(argv: argv, mode: .stream)
        case .antigravity:
            // agy -p consumes the following flag as its prompt and has no system-prompt flag.
            var argv = [
                "agy",
                "--input-format", "stream-json",
                "--output-format", "stream-json",
                "--settings", antigravitySettings,
            ]
            if let resume, !resume.isEmpty { argv += ["--conversation", resume] }
            return AssistantLaunch(argv: argv, mode: .stream)
        case .codex, .opencode:
            return AssistantLaunch(argv: [], mode: .perInput)
        case .terminal:
            return AssistantLaunch(argv: [], mode: .stream)
        }
    }

    /// Per-input command for `.perInput` providers; prepends `prompt` on the initial turn.
    public static func turn(_ p: SessionLauncher, input: String, prompt: String, resume: String?) -> [String] {
        let isInitial = resume?.isEmpty ?? true
        let effectiveInput = isInitial && !prompt.isEmpty ? "\(prompt)\n\n\(input)" : input
        switch p {
        case .codex:
            let flags = ["--json", "-c", #"approval_policy="never""#, "-c", #"sandbox_mode="read-only""#, "--skip-git-repo-check"]
            if let resume, !resume.isEmpty {
                return ["codex", "exec", "resume"] + flags + [resume, effectiveInput]
            }
            return ["codex", "exec"] + flags + [effectiveInput]
        case .opencode:
            var argv = ["opencode", "run", "--format", "json"]
            if let resume, !resume.isEmpty { argv += ["--session", resume] }
            argv.append(effectiveInput)
            return argv
        case .terminal, .claude, .antigravity:
            return []
        }
    }

    /// Extra environment variables needed to constrain tool permissions for a provider.
    public static func environment(_ p: SessionLauncher) -> [String: String] {
        switch p {
        case .opencode: ["OPENCODE_PERMISSION": opencodePermission]
        case .terminal, .claude, .codex, .antigravity: [:]
        }
    }
}
