import Foundation
import Testing
@testable import ElisCore

@MainActor
struct ControlDispatcherAssistantTests {
    private let peers = [
        AssistantPeer(sessionID: "claude1-uuid", window: "w1", workspaceID: "wsE", workspaceName: "elis", name: "claude 1",
                      agent: "claude", status: "idle"),
        AssistantPeer(sessionID: "shell1-uuid", window: "w2", workspaceID: "wsE", workspaceName: "elis", name: "zsh"),
        AssistantPeer(sessionID: "codex1-uuid", window: "w1", workspaceID: "wsM", workspaceName: "mobile", name: "codex run",
                      agent: "codex", status: "blocked"),
    ]

    private func actions() -> MockControlActions {
        let actions = MockControlActions()
        actions.peers = peers
        actions.providers = [.terminal, .claude, .codex]
        return actions
    }

    private func dispatch(_ cmd: Command, target: String? = nil, _ args: ControlArgs = ControlArgs(),
                          actions: MockControlActions, chat: AssistantChat) async -> ControlResponse? {
        await ControlDispatcher(actions: actions, chat: chat).dispatch(ControlRequest(cmd: cmd, target: target, args: args))
    }

    private func typed(_ actions: MockControlActions) -> [(target: String?, window: String?, text: String)] {
        actions.calls.compactMap {
            if case let .sessionType(target, window, options) = $0 { return (target, window, options.text) }
            return nil
        }
    }

    @Test func askAppendsAndFeedsTheStream() async throws {
        let (actions, chat) = (actions(), AssistantChat())

        let response = await dispatch(.assistantAsk, ControlArgs(text: "what is claude doing?"), actions: actions, chat: chat)

        let entry = try #require(response?.result?.assistant?.entries?.first)
        #expect(response?.ok == true)
        #expect(entry.kind == .user && entry.text == "what is claude doing?")
        #expect(chat.entries(last: nil) == [entry])
        #expect(actions.streamInputs == [entry])
        #expect(actions.streamTexts == ["what is claude doing?"])
    }

    @Test func askAndReplyMarkTheAssistantRunning() async {
        let (ask, askChat) = (actions(), AssistantChat())
        let (reply, replyChat) = (actions(), AssistantChat())

        _ = await dispatch(.assistantAsk, ControlArgs(text: "hi"), actions: ask, chat: askChat)
        _ = await dispatch(.assistantReply, target: "shell1-uuid", ControlArgs(text: "ok"), actions: reply, chat: replyChat)

        #expect(askChat.running && replyChat.running)
    }

    @Test func refusedAskLeavesTheAssistantIdle() async {
        let blank = AssistantChat()
        let unsupported = AssistantChat()

        _ = await dispatch(.assistantAsk, ControlArgs(text: " "), actions: actions(), chat: blank)
        _ = await dispatch(.assistantAsk, ControlArgs(text: "hi"), actions: MockControlActions(), chat: unsupported)

        #expect(!blank.running && !unsupported.running)
    }

    @Test func askRequiresText() async {
        let response = await dispatch(.assistantAsk, ControlArgs(text: "  \n"), actions: actions(), chat: AssistantChat())
        #expect(response?.error == "assistant.ask requires text")
    }

    @Test func sendTypesTheLineIntoEachTargetAndRecordsIt() async throws {
        let (actions, chat) = (actions(), AssistantChat())

        let response = await dispatch(.assistantSend, ControlArgs(text: "run the tests", recipients: ["@claude-1", "zsh"]),
                                      actions: actions, chat: chat)

        let line = try AssistantLine.make("run the tests") + "\n"
        let calls = typed(actions)
        #expect(calls.map(\.target) == ["claude1-uuid", "shell1-uuid"])
        #expect(calls.map(\.window) == ["w1", "w2"])
        #expect(calls.allSatisfy { $0.text == line })
        #expect(actions.calls.contains(.sessionType(target: "claude1-uuid", window: "w1",
                                                    ControlSessionTypeOptions(text: line, select: false, pane: nil))))
        #expect(response?.result?.assistant?.delivered == ["claude-1", "zsh"])
        #expect(response?.result?.assistant?.skipped == [])
        let sent = try #require(chat.entries(last: nil).last)
        #expect(sent.kind == .sent && sent.text == "run the tests" && sent.to == ["claude1-uuid", "shell1-uuid"])
        #expect(chat.marks == ["claude1-uuid": .waiting, "shell1-uuid": .waiting])
        #expect(actions.streamInputs.isEmpty)
        #expect(actions.sentEntries == [sent])
        #expect(response?.result?.assistant?.entries == [sent])
    }

    @Test func sendSkipsBlockedAndMarksThem() async throws {
        let (actions, chat) = (actions(), AssistantChat())

        let response = await dispatch(.assistantSend, ControlArgs(text: "hi", recipients: ["@all"]), actions: actions, chat: chat)

        #expect(typed(actions).map(\.target) == ["claude1-uuid"])
        #expect(response?.result?.assistant?.delivered == ["claude-1"])
        #expect(response?.result?.assistant?.skipped == [AssistantSkip(handle: "codex-run", reason: "blocked")])
        #expect(chat.marks["codex1-uuid"] == .notDelivered)
        #expect(chat.marks["claude1-uuid"] == .waiting)
    }

    @Test func sendSkipsATargetWhoseTypingFails() async throws {
        let (actions, chat) = (actions(), AssistantChat())
        actions.sessionTypeResponses["shell1-uuid"] = ControlResponse(ok: false, error: "session gone")

        let response = await dispatch(.assistantSend, ControlArgs(text: "hi", recipients: ["claude-1", "zsh"]),
                                      actions: actions, chat: chat)

        #expect(response?.ok == true)
        #expect(response?.result?.assistant?.delivered == ["claude-1"])
        #expect(response?.result?.assistant?.skipped == [AssistantSkip(handle: "zsh", reason: "failed: session gone")])
        #expect(chat.entries(last: nil).last?.to == ["claude1-uuid"])
        #expect(chat.marks["shell1-uuid"] == .notDelivered)
    }

    @Test func sendAppendsNothingWhenNobodyIsDelivered() async throws {
        let (actions, chat) = (actions(), AssistantChat())

        let response = await dispatch(.assistantSend, ControlArgs(text: "hi", recipients: ["codex-run"]), actions: actions, chat: chat)

        #expect(response?.ok == true)
        #expect(response?.result?.assistant?.delivered == [])
        #expect(response?.result?.assistant?.entries == nil)
        #expect(actions.sentEntries.isEmpty)
        #expect(chat.entries(last: nil).isEmpty)
        #expect(chat.marks == ["codex1-uuid": .notDelivered])
    }

    @Test func sendUnknownTagFailsWithoutTyping() async {
        let (actions, chat) = (actions(), AssistantChat())

        let unknown = await dispatch(.assistantSend, ControlArgs(text: "hi", recipients: ["claude-1", "@nobody"]),
                                     actions: actions, chat: chat)
        let empty = await dispatch(.assistantSend, ControlArgs(text: " ", recipients: ["claude-1"]), actions: actions, chat: chat)
        let noTags = await dispatch(.assistantSend, ControlArgs(text: "hi"), actions: actions, chat: chat)

        #expect(unknown?.error == "unknown tag @nobody")
        #expect(empty?.error == "empty message")
        #expect(noTags?.error == "assistant.send requires --to")
        #expect(typed(actions).isEmpty)
        #expect(chat.entries(last: nil).isEmpty)
    }

    @Test(arguments: ["shell1-uuid", "SHE"])
    func replyFromKnownSessionFeedsTheStreamWithItsHandle(target: String) async throws {
        let (actions, chat) = (actions(), AssistantChat())

        let response = await dispatch(.assistantReply, target: target, ControlArgs(text: "tests pass"), actions: actions, chat: chat)

        let stored = try #require(chat.entries(last: nil).last)
        #expect(response?.ok == true)
        #expect(stored.kind == .reply && stored.from == "shell1-uuid" && stored.text == "tests pass")
        #expect(actions.streamInputs == [stored])
        #expect(actions.streamTexts == ["[reply from @zsh shell1-uuid] tests pass"])
        #expect(chat.entries(last: nil).count == 1)
    }

    @Test func replyFromUnknownSessionIsRefused() async {
        let (actions, chat) = (actions(), AssistantChat())

        let unknown = await dispatch(.assistantReply, target: "active", ControlArgs(text: "x"), actions: actions, chat: chat)
        let ambiguous = await dispatch(.assistantReply, target: "c", ControlArgs(text: "x"), actions: actions, chat: chat)
        let missing = await dispatch(.assistantReply, ControlArgs(text: "x"), actions: actions, chat: chat)

        #expect(unknown?.error == "assistant.reply: unknown session active")
        #expect(ambiguous?.error == "assistant.reply: unknown session c")
        #expect(missing?.error == "assistant.reply requires a session")
        #expect(chat.entries(last: nil).isEmpty && actions.streamInputs.isEmpty)
    }

    @Test func readHonoursLast() async throws {
        let (actions, chat) = (actions(), AssistantChat())
        for text in ["a", "b", "c"] { chat.append(.user, text: text, now: 0) }
        var args = ControlArgs()
        args.last = 2

        let last = await dispatch(.assistantRead, args, actions: actions, chat: chat)
        let all = await dispatch(.assistantRead, actions: actions, chat: chat)
        args.last = 0
        let zero = await dispatch(.assistantRead, args, actions: actions, chat: chat)

        #expect(last?.result?.assistant?.entries?.map(\.text) == ["b", "c"])
        #expect(all?.result?.assistant?.entries?.map(\.text) == ["a", "b", "c"])
        #expect(zero?.error == "assistant.read: --last must be positive")
    }

    @Test func providerReadsAndSets() async throws {
        let (actions, chat) = (actions(), AssistantChat())
        var args = ControlArgs()
        args.provider = "codex"

        let bare = await dispatch(.assistantProvider, actions: actions, chat: chat)
        let set = await dispatch(.assistantProvider, args, actions: actions, chat: chat)

        #expect(bare?.result?.assistant == ControlAssistantResult(providers: ["claude", "codex"]))
        #expect(set?.result?.assistant == ControlAssistantResult(provider: "codex", providers: ["claude", "codex"]))
        #expect(chat.provider == .codex)
        #expect(actions.changedProviders == [.codex])
    }

    @Test(arguments: ["opencode", "terminal"])
    func providerRejectsUnavailable(name: String) async {
        let (actions, chat) = (actions(), AssistantChat())
        var args = ControlArgs()
        args.provider = name

        let response = await dispatch(.assistantProvider, args, actions: actions, chat: chat)

        #expect(response?.error == "unknown provider \(name); available: claude, codex")
        #expect(chat.provider == nil && actions.changedProviders.isEmpty)
    }

    @Test func showDelegatesAndMarksSeenOnSuccess() async {
        let (actions, chat) = (actions(), AssistantChat())
        chat.append(.reply, text: "x", from: "shell1-uuid", now: 0)

        let refused = await dispatch(.assistantShow, ControlArgs(window: "w1"), actions: actions, chat: chat)
        #expect(refused?.ok == false && chat.unread == 1)
        actions.nextShowAssistantResponse = ControlResponse(ok: true)
        let shown = await dispatch(.assistantShow, ControlArgs(window: "w1"), actions: actions, chat: chat)

        #expect(shown?.ok == true && chat.unread == 0)
        #expect(actions.showWindows == ["w1", "w1"])
    }

    @Test(arguments: [Command.assistantAsk, .assistantSend, .assistantReply, .assistantRead, .assistantProvider, .assistantShow])
    func everyAssistantCommandRefusesOnAHostWithoutSupport(cmd: Command) async {
        var args = ControlArgs(text: "hi", recipients: ["claude-1"])
        args.provider = "claude"
        let response = await dispatch(cmd, target: "shell1-uuid", args, actions: MockControlActions(), chat: AssistantChat())
        #expect(response?.error == ControlActionsUnsupported.message(cmd.rawValue))
    }

    private func hostTree() -> ControlResponse {
        let sessions = ["claude1-uuid", "shell1-uuid"].map {
            ControlSessionNode(id: $0, name: $0, cwd: "/", active: false, split: false, backedByZmx: nil)
        }
        let workspace = ControlWorkspaceNode(id: "wsE", name: "elis", active: true, sessions: sessions)
        return ControlResponse(ok: true, result: ControlResult(tree: ControlTree(workspaces: [workspace])))
    }

    @Test func treeCarriesHandlesMarksAndTheAssistantNode() async throws {
        let (actions, chat) = (actions(), AssistantChat())
        actions.nextTreeResponse = hostTree()
        chat.provider = .claude
        chat.append(.sent, text: "go", to: ["claude1-uuid"], now: 0)
        chat.inputQueued()

        let tree = try #require(await dispatch(.tree, actions: actions, chat: chat)?.result?.tree)

        let workspace = try #require(tree.workspaces.first)
        #expect(workspace.handle == "elis")
        #expect(workspace.sessions.map(\.handle) == ["claude-1", "zsh"])
        #expect(workspace.sessions.map(\.assistantMark) == ["waiting", nil])
        #expect(tree.assistant == ControlAssistantNode(provider: "claude", providers: ["claude", "codex"], running: true, unread: 0))

        let handle = try #require(workspace.sessions[1].handle)
        _ = await dispatch(.assistantSend, ControlArgs(text: "hi", recipients: ["@\(handle)"]), actions: actions, chat: chat)
        #expect(typed(actions).map(\.target) == ["shell1-uuid"])
    }

    @Test func treeIsUntouchedOnAHostWithoutTheAssistant() async {
        let actions = MockControlActions()
        actions.nextTreeResponse = hostTree()
        #expect(await dispatch(.tree, actions: actions, chat: AssistantChat()) == hostTree())
    }

    @Test func treeOmitsAssistantWhenNil() throws {
        let workspace = ControlWorkspaceNode(id: "w", name: "w", active: true, sessions: [
            ControlSessionNode(id: "s", name: "s", cwd: "/", active: true, split: false, backedByZmx: nil),
        ])
        let json = String(decoding: try JSONEncoder().encode(ControlTree(workspaces: [workspace])), as: UTF8.self)
        #expect(!json.contains("\"assistant\"") && !json.contains("\"handle\"") && !json.contains("\"assistantMark\""))

        var tree = ControlTree(workspaces: [workspace])
        tree.assistant = ControlAssistantNode(provider: "claude", providers: ["claude"], running: true, unread: 2)
        #expect(try JSONDecoder().decode(ControlTree.self, from: JSONEncoder().encode(tree)) == tree)
    }

    @Test(arguments: [Command.assistantAsk, .assistantSend, .assistantReply, .assistantRead, .assistantProvider, .assistantShow])
    func requestRoundTrips(cmd: Command) throws {
        var args = ControlArgs(text: "hi", window: "w1", recipients: ["@all"])
        args.last = 3
        args.provider = "codex"
        let request = ControlRequest(cmd: cmd, target: "s1", args: args)
        #expect(try JSONDecoder().decode(ControlRequest.self, from: JSONEncoder().encode(request)) == request)
    }
}
