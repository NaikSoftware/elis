import Foundation
import Testing
@testable import ElisCore

@Suite struct AssistantProviderTests {
    private static func fixtureLines(_ name: String) throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/assistant/\(name).jsonl")
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    @Test func choicesDropTerminal() {
        let choices = AssistantProvider.choices([.terminal, .claude, .codex, .opencode, .antigravity])
        #expect(choices == [.claude, .codex, .opencode, .antigravity])
    }

    @Test func claudeLaunchIsStreamWithoutPermissionPrompts() {
        let first = AssistantProvider.launch(.claude, prompt: "Be concise.", resume: nil)
        #expect(first == AssistantLaunch(argv: [
            "claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--permission-mode", "bypassPermissions", "--append-system-prompt", "Be concise.",
        ], mode: .stream, environment: [:], preamble: nil))

        let resumed = AssistantProvider.launch(.claude, prompt: "Be concise.", resume: "sess-123")
        #expect(resumed.argv.suffix(2) == ["--resume", "sess-123"])
        #expect(resumed.preamble == nil)
    }

    @Test func antigravityLaunchSkipsPermissionsAndCarriesThePrompt() {
        let first = AssistantProvider.launch(.antigravity, prompt: "Be concise.", resume: nil)
        #expect(first == AssistantLaunch(argv: [
            "agy", "--dangerously-skip-permissions", "--input-format", "stream-json", "--output-format", "stream-json",
        ], mode: .stream, environment: [:], preamble: "Be concise.\n\n"))

        let resumed = AssistantProvider.launch(.antigravity, prompt: "Be concise.", resume: "conv-456")
        #expect(resumed.argv.suffix(2) == ["--conversation", "conv-456"])
        #expect(resumed.preamble == nil)
    }

    @Test func codexTurnBypassesApprovalsAndEndsOptions() {
        #expect(AssistantProvider.launch(.codex, prompt: "sys", resume: nil) == AssistantLaunch(argv: [], mode: .perInput))
        let flags = ["--json", "--dangerously-bypass-approvals-and-sandbox", "--skip-git-repo-check", "--"]

        let first = AssistantProvider.turn(.codex, input: "pong", prompt: "sys", resume: nil)
        #expect(first == ["codex", "exec"] + flags + ["sys\n\npong"])

        let resumed = AssistantProvider.turn(.codex, input: "--help", prompt: "sys", resume: "thread-1")
        #expect(resumed == ["codex", "exec", "resume"] + flags + ["thread-1", "--help"])
    }

    @Test func opencodeTurnAutoApprovesAndEndsOptions() {
        #expect(AssistantProvider.launch(.opencode, prompt: "sys", resume: nil) == AssistantLaunch(argv: [], mode: .perInput))

        let first = AssistantProvider.turn(.opencode, input: "pong", prompt: "sys", resume: nil)
        #expect(first == ["opencode", "run", "--format", "json", "--auto", "--", "sys\n\npong"])

        let resumed = AssistantProvider.turn(.opencode, input: "--help", prompt: "sys", resume: "ses_1")
        #expect(resumed == ["opencode", "run", "--format", "json", "--auto", "--session", "ses_1", "--", "--help"])
    }

    @Test func encodeProducesOneLine() throws {
        let payload = "line 1\nline \"2\" \\ end"
        for provider in [SessionLauncher.claude, .antigravity] {
            let line = AssistantStream.encode(provider, text: payload)
            #expect(!line.isEmpty)
            #expect(!line.contains("\n"))
            #expect(!line.contains("\r"))
            let obj = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            let message = try #require(obj["message"] as? [String: Any])
            if provider == .claude {
                let content = try #require(message["content"] as? [[String: Any]])
                #expect(content.first?["text"] as? String == payload)
            } else {
                #expect(message["content"] as? String == payload)
            }
        }
        #expect(AssistantStream.encode(.codex, text: payload).isEmpty)
        #expect(AssistantStream.encode(.opencode, text: payload).isEmpty)
    }

    @Test func decodeClaudeFixture() throws {
        let events = try Self.fixtureLines("claude").flatMap { AssistantStream.decode(.claude, line: $0) }
        #expect(events == [
            .conversation("6543c69f-a6a3-4705-8dcf-769f64e99baa"),
            .text("pong"),
            .turnEnded(error: nil),
            .text("ping"),
            .turnEnded(error: nil),
        ])
    }

    @Test func decodeAntigravityFixture() throws {
        let events = try Self.fixtureLines("antigravity").flatMap { AssistantStream.decode(.antigravity, line: $0) }
        #expect(events == [
            .conversation("bac4b533-7bc3-4ad8-bad7-5ebb1121ab06"),
            .text("pong"),
            .turnEnded(error: nil),
            .text("ping"),
            .turnEnded(error: nil),
        ])
    }

    @Test func decodeCodexFixture() throws {
        let events = try Self.fixtureLines("codex").flatMap { AssistantStream.decode(.codex, line: $0) }
        #expect(events == [
            .conversation("0199a213-81c0-7800-8aa1-bbab2a035a53"),
            .text("pong"),
            .turnEnded(error: nil),
            .conversation("0199a213-81c0-7800-8aa1-bbab2a035a53"),
            .text("ping"),
            .turnEnded(error: nil),
        ])
    }

    @Test func decodeOpenCodeFixture() throws {
        let events = try Self.fixtureLines("opencode").flatMap { AssistantStream.decode(.opencode, line: $0) }
        #expect(events == [
            .conversation("ses_494719016ffe85dkDMj0FPRbHK"),
            .text("pong"),
            .turnEnded(error: nil),
            .conversation("ses_494719016ffe85dkDMj0FPRbHK"),
            .text("ping"),
            .turnEnded(error: nil),
        ])
    }

    @Test func nonJSONLineDecodesToNothing() {
        for provider in SessionLauncher.allCases {
            #expect(AssistantStream.decode(provider, line: "warning: x") == [])
            #expect(AssistantStream.decode(provider, line: "") == [])
        }
    }

    @Test func decodesErrorsPerProvider() {
        #expect(AssistantStream.decode(.claude, line: #"{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["boom"]}"#) == [.turnEnded(error: "boom")])
        #expect(AssistantStream.decode(.antigravity, line: #"{"event":"result","result":{"status":"ERROR","error":"denied"}}"#) == [.turnEnded(error: "denied")])
        #expect(AssistantStream.decode(.antigravity, line: #"{"event":"result","result":{"status":"ERROR","response":"half","error":"cut"}}"#) == [
            .text("half"), .turnEnded(error: "cut"),
        ])
        #expect(AssistantStream.decode(.codex, line: #"{"type":"turn.failed","error":{"message":"unauthorized"}}"#) == [.turnEnded(error: "unauthorized")])
        #expect(AssistantStream.decode(.opencode, line: #"{"type":"error","sessionID":"ses_1","error":{"name":"APIError","data":{"message":"bad key"}}}"#) == [.turnEnded(error: "bad key")])
    }
}
