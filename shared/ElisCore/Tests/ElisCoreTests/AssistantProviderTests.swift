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

    @Test func claudeLaunchIsStreamWithElisctlOnly() {
        let first = AssistantProvider.launch(.claude, prompt: "Be concise.", resume: nil)
        #expect(first.mode == .stream)
        #expect(first.argv.first == "claude")
        #expect(first.argv.contains("-p"))
        #expect(first.argv.contains("--input-format"))
        #expect(first.argv.contains("stream-json"))
        #expect(first.argv.contains("--output-format"))
        #expect(first.argv.contains("Bash(elisctl:*)"))
        #expect(first.argv.contains("--append-system-prompt"))
        #expect(first.argv.contains("Be concise."))
        #expect(!first.argv.contains("--resume"))

        let resumed = AssistantProvider.launch(.claude, prompt: "Be concise.", resume: "sess-123")
        #expect(resumed.mode == .stream)
        #expect(resumed.argv.contains("--resume"))
        #expect(resumed.argv.contains("sess-123"))
    }

    @Test func antigravityLaunchIsStreamWithElisctlSettings() throws {
        let first = AssistantProvider.launch(.antigravity, prompt: "Be concise.", resume: nil)
        #expect(first.mode == .stream)
        #expect(first.argv.first == "agy")
        #expect(!first.argv.contains("-p"))
        #expect(first.argv.contains("--input-format"))
        #expect(first.argv.contains("--output-format"))
        #expect(first.argv.contains("stream-json"))
        let settingsIdx = try #require(first.argv.firstIndex(of: "--settings"))
        let settings = first.argv[settingsIdx + 1]
        #expect(settings.contains("command(elisctl)"))
        #expect(settings.contains("request-review"))
        #expect(!first.argv.contains("--conversation"))

        let resumed = AssistantProvider.launch(.antigravity, prompt: "Be concise.", resume: "conv-456")
        #expect(resumed.argv.contains("--conversation"))
        #expect(resumed.argv.contains("conv-456"))
    }

    @Test func codexTurnUsesExecAndResumeWithReadOnlySandbox() {
        #expect(AssistantProvider.launch(.codex, prompt: "sys", resume: nil).mode == .perInput)

        let first = AssistantProvider.turn(.codex, input: "pong", prompt: "sys", resume: nil)
        #expect(first.prefix(3) == ["codex", "exec", "--json"])
        #expect(first.contains(#"sandbox_mode="read-only""#))
        #expect(first.contains(#"approval_policy="never""#))
        #expect(first.last == "sys\n\npong")

        let resumed = AssistantProvider.turn(.codex, input: "ping", prompt: "sys", resume: "thread-1")
        #expect(resumed.prefix(4) == ["codex", "exec", "resume", "--json"])
        #expect(resumed.contains(#"sandbox_mode="read-only""#))
        #expect(resumed.contains(#"approval_policy="never""#))
        #expect(resumed.suffix(2) == ["thread-1", "ping"])
    }

    @Test func opencodeTurnUsesRunFormatJsonAndElisctlEnv() {
        #expect(AssistantProvider.launch(.opencode, prompt: "sys", resume: nil).mode == .perInput)

        let first = AssistantProvider.turn(.opencode, input: "pong", prompt: "sys", resume: nil)
        #expect(first == ["opencode", "run", "--format", "json", "sys\n\npong"])

        let resumed = AssistantProvider.turn(.opencode, input: "ping", prompt: "sys", resume: "ses_1")
        #expect(resumed == ["opencode", "run", "--format", "json", "--session", "ses_1", "ping"])

        let env = AssistantProvider.environment(.opencode)
        let perm = env["OPENCODE_PERMISSION"] ?? ""
        #expect(perm.contains("elisctl *"))
        #expect(perm.contains("deny"))
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
            .text("\n"),
            .turnEnded(error: nil),
            .text("ping"),
            .text("\n"),
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
        #expect(AssistantStream.decode(.codex, line: #"{"type":"turn.failed","error":{"message":"unauthorized"}}"#) == [.turnEnded(error: "unauthorized")])
        #expect(AssistantStream.decode(.opencode, line: #"{"type":"error","sessionID":"ses_1","error":{"name":"APIError","data":{"message":"bad key"}}}"#) == [.turnEnded(error: "bad key")])
    }
}
