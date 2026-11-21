import Testing
@testable import ElisCore

@Suite struct AssistantTargetsTests {
    // "claude 1" (claude1, claude, idle) and "zsh" (shell1, no agent) in "elis"; "codex run" (codex1, codex, blocked) in "mobile"
    let directory = AssistantDirectory([
        AssistantPeer(sessionID: "claude1", window: "w1", workspaceID: "wsE", workspaceName: "elis", name: "claude 1", agent: "claude", status: "idle"),
        AssistantPeer(sessionID: "shell1", window: "w1", workspaceID: "wsE", workspaceName: "elis", name: "zsh", agent: nil, status: nil),
        AssistantPeer(sessionID: "codex1", window: "w1", workspaceID: "wsM", workspaceName: "mobile", name: "codex run", agent: "codex", status: "blocked"),
    ])

    @Test func allReachesAgentsOnlyAndSkipsBlocked() throws {
        let d = try AssistantTargets.resolve(["@all"], in: directory)
        #expect(d.targets.map(\.sessionID) == ["claude1"])
        #expect(d.skipped == [AssistantSkip(handle: "codex-run", reason: "blocked")])
    }

    @Test func workspaceTagExpandsToItsAgents() throws {
        #expect(try AssistantTargets.resolve(["@ws:elis"], in: directory).targets.map(\.sessionID) == ["claude1"])
    }

    @Test func explicitTagReachesAPlainShell() throws {
        #expect(try AssistantTargets.resolve(["@zsh"], in: directory).targets.map(\.sessionID) == ["shell1"])
    }

    @Test func explicitTagToABlockedAgentIsSkipped() throws {
        let d = try AssistantTargets.resolve(["codex-run"], in: directory)
        #expect(d.targets.isEmpty && d.skipped.map(\.handle) == ["codex-run"])
    }

    @Test func duplicatesCollapseAndUnknownTagsThrow() throws {
        #expect(try AssistantTargets.resolve(["@all", "@claude-1"], in: directory).targets.count == 1)
        #expect(throws: AssistantTagError.self) { try AssistantTargets.resolve(["@nobody"], in: directory) }
        #expect(throws: AssistantTagError.self) { try AssistantTargets.resolve([], in: directory) }
    }

    @Test func errorMessages() {
        #expect(AssistantTagError.unknown("x").message == "unknown tag @x")
        #expect(AssistantTagError.noTags.message == "no tags")
        #expect(AssistantLineError.nul.message == "text must not contain a NUL byte")
        #expect(AssistantLineError.empty.message == "empty message")
    }

    @Test func lineFoldsNewlinesAndKeepsTheHint() throws {
        #expect(try AssistantLine.make("a\nb\t\"c\"") == "[Elis] a b \"c\" — reply: elisctl reply \"<answer>\"")
        let long = try AssistantLine.make(String(repeating: "я", count: 5000))
        #expect(long.utf8.count <= AssistantLine.maxBytes && long.hasSuffix("elisctl reply \"<answer>\""))
    }

    @Test func lineRefusesNulAndBlank() {
        #expect(throws: AssistantLineError.self) { try AssistantLine.make("a\u{0}b") }
        #expect(throws: AssistantLineError.self) { try AssistantLine.make(" \n ") }
    }
}
