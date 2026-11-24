import Foundation
import Testing
@testable import ElisCore

@MainActor
struct AssistantCommandsCoreTests {
    private let peers = [
        AssistantPeer(sessionID: "claude1-uuid", window: "w1", workspaceID: "wsE", workspaceName: "elis", name: "claude 1",
                      agent: "claude", status: "idle"),
        AssistantPeer(sessionID: "shell1-uuid", window: "w2", workspaceID: "wsE", workspaceName: "elis", name: "zsh"),
        AssistantPeer(sessionID: "codex1-uuid", window: "w1", workspaceID: "wsM", workspaceName: "mobile", name: "codex run",
                      agent: "codex", status: "blocked"),
    ]

    private func run(_ cmd: Command, target: String? = nil, _ args: ControlArgs, chat: AssistantChat,
                     peers: [AssistantPeer]?? = .none) -> AssistantStep {
        AssistantCommands(chat: chat).run(ControlRequest(cmd: cmd, target: target, args: args),
                                          peers: peers ?? self.peers, providers: [.terminal, .claude, .codex])
    }

    private func reply(_ step: AssistantStep) throws -> (ControlResponse, [AssistantEffect]) {
        guard case let .reply(response, effects) = step else { throw Unexpected.step }
        return (response, effects)
    }

    private func plan(_ step: AssistantStep) throws -> AssistantSendPlan {
        guard case let .send(plan) = step else { throw Unexpected.step }
        return plan
    }

    private enum Unexpected: Error { case step }

    @Test func askRepliesWithOneInputEffect() throws {
        let chat = AssistantChat()

        let (response, effects) = try reply(run(.assistantAsk, ControlArgs(text: "hi"), chat: chat))

        let entry = try #require(response.result?.assistant?.entries?.first)
        #expect(response.ok && chat.running)
        #expect(effects == [.input(entry, streamText: "hi")])
    }

    @Test func sendPlansTheTypedLine() throws {
        let chat = AssistantChat()

        let plan = try plan(run(.assistantSend, ControlArgs(text: "run the tests", recipients: ["@claude-1", "zsh", "codex-run"]),
                                chat: chat))

        #expect(plan.line == (try AssistantLine.typed("run the tests")).line)
        #expect(plan.body == "run the tests" && !plan.cut)
        #expect(plan.targets.map(\.sessionID) == ["claude1-uuid", "shell1-uuid"])
        #expect(plan.handles == ["claude1-uuid": "claude-1", "shell1-uuid": "zsh"])
        #expect(plan.skipped.map(\.handle) == ["codex-run"] && plan.skippedIDs == ["codex1-uuid"])
        #expect(chat.entries(last: nil).isEmpty)
    }

    @Test func finishSendRecordsDeliveredAndFailed() throws {
        let chat = AssistantChat()
        let long = String(repeating: "word ", count: 400)
        let commands = AssistantCommands(chat: chat)
        let plan = try plan(run(.assistantSend, ControlArgs(text: long, recipients: ["claude-1", "zsh"]), chat: chat))

        let (response, effects) = try reply(commands.finishSend(plan, failures: ["claude1-uuid": "pane gone"]))

        let result = try #require(response.result?.assistant)
        let sent = try #require(result.entries?.first)
        #expect(response.ok && result.cut == true)
        #expect(result.delivered == ["zsh"] && result.deliveredIDs == ["shell1-uuid"])
        #expect(result.skipped == [AssistantSkip(handle: "claude-1", reason: "failed: pane gone")])
        #expect(sent.kind == .sent && sent.to == ["shell1-uuid"] && sent.text == plan.body)
        #expect(effects == [.sent(sent)])
        #expect(chat.marks == ["claude1-uuid": .notDelivered, "shell1-uuid": .waiting])
    }

    @Test func replyEffectCarriesTheSender() throws {
        let (response, effects) = try reply(run(.assistantReply, target: "shell1-uuid", ControlArgs(text: "tests pass"),
                                                chat: AssistantChat()))

        let stored = try #require(response.result?.assistant?.entries?.first)
        #expect(effects == [.input(stored, streamText: "[reply from @zsh shell1-uuid] tests pass")])
    }

    @Test func showRepliesWithTheShowEffect() throws {
        let (response, effects) = try reply(run(.assistantShow, ControlArgs(window: "w1"), chat: AssistantChat()))
        #expect(response.ok && effects == [.show(window: "w1")])
    }

    @Test func seenClearsUnreadAndRepliesWithTheSeenEffect() throws {
        let chat = AssistantChat()
        chat.append(.reply, text: "done", from: "shell1-uuid", now: 0)
        #expect(chat.unread == 1)
        let (response, effects) = try reply(run(.assistantSeen, ControlArgs(), chat: chat))
        #expect(response.ok && effects == [.seen] && chat.unread == 0)
    }

    @Test func clearEmptiesTheChatAndRepliesWithTheClearedEffect() throws {
        let chat = AssistantChat()
        chat.append(.user, text: "hi", now: 0)
        let (response, effects) = try reply(run(.assistantClear, ControlArgs(), chat: chat))
        #expect(response.ok && effects == [.cleared] && chat.entries(last: nil).isEmpty)
    }

    @Test(arguments: [Command.assistantAsk, .assistantSend, .assistantReply, .assistantRead, .assistantSeen, .assistantClear])
    func nilPeersRefuse(cmd: Command) throws {
        let (response, effects) = try reply(run(cmd, target: "shell1-uuid", ControlArgs(text: "hi", recipients: ["zsh"]),
                                                chat: AssistantChat(), peers: .some(nil)))
        #expect(response.error == ControlActionsUnsupported.message(cmd.rawValue) && effects.isEmpty)
    }

    @Test func stampMatchesTheDispatcher() async throws {
        let chat = AssistantChat()
        chat.provider = .claude
        chat.append(.sent, text: "go", to: ["claude1-uuid"], now: 0)
        let actions = MockControlActions()
        actions.peers = peers
        actions.providers = [.terminal, .claude, .codex]
        let sessions = ["claude1-uuid", "shell1-uuid"].map {
            ControlSessionNode(id: $0, name: $0, cwd: "/", active: false, split: false, backedByZmx: nil)
        }
        let tree = ControlTree(workspaces: [ControlWorkspaceNode(id: "wsE", name: "elis", active: true, sessions: sessions)])
        actions.nextTreeResponse = ControlResponse(ok: true, result: ControlResult(tree: tree))

        let dispatched = try #require(await ControlDispatcher(actions: actions, chat: chat).dispatch(ControlRequest(cmd: .tree)))

        let stamped = AssistantCommands(chat: chat).stamp(tree, peers: peers, providers: actions.providers)
        #expect(stamped == dispatched.result?.tree)
        #expect(stamped.assistant == ControlAssistantNode(provider: "claude", providers: ["claude", "codex"], running: false, unread: 0))
        #expect(stamped.workspaces[0].sessions.map(\.handle) == ["claude-1", "zsh"])
        #expect(stamped.workspaces[0].sessions.map(\.assistantMark) == ["waiting", nil])
        #expect(AssistantCommands(chat: chat).stamp(tree, peers: nil, providers: nil) == tree)
    }

    @Test func stampJSONAddsWhatStampAdds() throws {
        let chat = AssistantChat()
        chat.provider = .claude
        chat.append(.sent, text: "go", to: ["claude1-uuid"], now: 0)
        let commands = AssistantCommands(chat: chat)
        let sessions = ["claude1-uuid", "shell1-uuid"].map {
            ControlSessionNode(id: $0, name: $0, cwd: "/", active: false, split: false, backedByZmx: nil)
        }
        let tree = ControlTree(workspaces: [ControlWorkspaceNode(id: "wsE", name: "elis", active: true, sessions: sessions)])
        let plain = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(tree)) as? [String: Any])
        let sorted = { (object: Any) in try JSONSerialization.data(withJSONObject: object, options: .sortedKeys) }
        var hostTree = plain
        hostTree["linuxOnly"] = 1

        var viaJSON = try commands.stampJSON(hostTree, peers: peers, providers: [.claude, .codex])

        let typed = try JSONSerialization.jsonObject(with: JSONEncoder().encode(commands.stamp(tree, peers: peers, providers: [.claude, .codex])))
        #expect(viaJSON.removeValue(forKey: "linuxOnly") as? Int == 1)
        #expect(try sorted(viaJSON) == sorted(typed))
        #expect(try sorted(commands.stampJSON(plain, peers: nil, providers: nil)) == sorted(plain))
    }
}
