import ArgumentParser
import Foundation
import Testing
import ElisCore
@testable import elisctlKit

struct AssistantCommandsTests {
    private let session = "AAAA1111-0000-4000-8000-000000000001"
    private let entryID = UUID(uuidString: "CCCC3333-0000-4000-8000-000000000003")!
    private let replyID = UUID(uuidString: "DDDD4444-0000-4000-8000-000000000004")!

    private final class FakeApp {
        var replies: [ControlResponse]
        var requests: [ControlRequest] = []
        var sleeps: [TimeInterval] = []
        var clock: TimeInterval = 0

        init(_ replies: [ControlResponse]) { self.replies = replies }

        var dependencies: AssistantAskDependencies {
            AssistantAskDependencies(
                send: { request in
                    self.requests.append(request)
                    let response = self.replies.count > 1 ? self.replies.removeFirst() : self.replies[0]
                    return SocketReply(response: response, raw: try JSONEncoder().encode(response))
                },
                sleep: { delay in
                    self.sleeps.append(delay)
                    self.clock += delay
                },
                now: { self.clock }
            )
        }
    }

    private func parseAssistant<T: ParsableCommand>(_ argv: [String], as type: T.Type) throws -> T {
        try #require(try Elisctl.parseAsRoot(["assistant"] + argv) as? T)
    }

    private func parseReply(_ argv: [String]) throws -> Reply {
        try #require(try Elisctl.parseAsRoot(["reply"] + argv) as? Reply)
    }

    private func reply(_ result: ControlResult?, ok: Bool = true, error: String? = nil) throws -> SocketReply {
        let response = ControlResponse(ok: ok, result: result, error: error)
        return SocketReply(response: response, raw: try JSONEncoder().encode(response))
    }

    private func entry(_ id: UUID, kind: AssistantEntry.Kind, from: String? = nil, to: [String]? = nil,
                       text: String, ts: Double = 0) throws -> AssistantEntry {
        var object: [String: Any] = ["id": id.uuidString, "kind": kind.rawValue, "text": text, "ts": ts]
        if let from { object["from"] = from }
        if let to { object["to"] = to }
        return try JSONDecoder().decode(AssistantEntry.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func treeResponse(running: Bool) -> ControlResponse {
        var tree = ControlTree(workspaces: [])
        tree.assistant = ControlAssistantNode(provider: "claude", providers: ["claude"], running: running, unread: 0)
        return ControlResponse(ok: true, result: ControlResult(tree: tree))
    }

    @Test func askBuildsRequestAndRejectsInvalidTimeoutOptions() throws {
        let ask = try parseAssistant(["ask", "what is claude doing?"], as: Assistant.Ask.self)
        #expect(ask.makeRequest() == ControlRequest(cmd: .assistantAsk, args: ControlArgs(text: "what is claude doing?")))

        for argv in [
            ["ask"],
            ["ask", "hi", "--timeout", "5"],
            ["ask", "hi", "--wait", "--timeout", "0"],
            ["ask", "hi", "--wait", "--timeout", "-1"],
        ] {
            #expect(throws: (any Error).self) { try Elisctl.parseAsRoot(["assistant"] + argv) }
        }
    }

    @Test func sendParsesRepeatableToAndExclusiveStdin() throws {
        let send = try parseAssistant(["send", "--to", "@claude-1", "--to", "@ws:elis", "run tests"], as: Assistant.Send.self)
        #expect(send.makeRequest(body: "run tests") == ControlRequest(
            cmd: .assistantSend,
            args: ControlArgs(text: "run tests", recipients: ["@claude-1", "@ws:elis"])
        ))

        let fromStdin = try parseAssistant(["send", "--to", "@all", "--stdin"], as: Assistant.Send.self)
        #expect(fromStdin.makeRequest(body: "from stdin") == ControlRequest(
            cmd: .assistantSend,
            args: ControlArgs(text: "from stdin", recipients: ["@all"])
        ))

        for argv in [
            ["send", "hi"],
            ["send", "--to", "@all"],
            ["send", "--to", "@all", "hi", "--stdin"],
        ] {
            #expect(throws: (any Error).self) { try Elisctl.parseAsRoot(["assistant"] + argv) }
        }
    }

    @Test func readParsesLastAndRejectsNonPositiveValues() throws {
        let bare = try parseAssistant(["read"], as: Assistant.Read.self)
        #expect(bare.makeRequest() == ControlRequest(cmd: .assistantRead))

        let limited = try parseAssistant(["read", "--last", "5"], as: Assistant.Read.self)
        var args = ControlArgs()
        args.last = 5
        #expect(limited.makeRequest() == ControlRequest(cmd: .assistantRead, args: args))

        for argv in [["read", "--last", "0"], ["read", "--last", "-2"]] {
            #expect(throws: (any Error).self) { try Elisctl.parseAsRoot(["assistant"] + argv) }
        }
    }

    @Test func providerAndShowBuildExpectedRequests() throws {
        let readProvider = try parseAssistant(["provider"], as: Assistant.Provider.self)
        #expect(readProvider.makeRequest() == ControlRequest(cmd: .assistantProvider))

        let setProvider = try parseAssistant(["provider", "codex"], as: Assistant.Provider.self)
        var providerArgs = ControlArgs()
        providerArgs.provider = "codex"
        #expect(setProvider.makeRequest() == ControlRequest(cmd: .assistantProvider, args: providerArgs))

        let show = try parseAssistant(["show", "--window", "w1"], as: Assistant.Show.self)
        #expect(try show.makeRequest() == ControlRequest(cmd: .assistantShow, args: ControlArgs(window: "w1")))
    }

    @Test func replyBuildsRequestInsideSessionAndParsesStdinMutuallyExclusive() throws {
        let cmd = try parseReply(["tests pass"])
        let req = try CallerEnvironment.$values.withValue(["ELIS_SESSION_ID": session]) {
            try cmd.makeRequest(body: "tests pass")
        }
        #expect(req == ControlRequest(cmd: .assistantReply, target: session, args: ControlArgs(text: "tests pass")))

        let stdinCmd = try parseReply(["--stdin"])
        let stdinReq = try CallerEnvironment.$values.withValue(["ELIS_SESSION_ID": session]) {
            try stdinCmd.makeRequest(body: "from pipe")
        }
        #expect(stdinReq == ControlRequest(cmd: .assistantReply, target: session, args: ControlArgs(text: "from pipe")))

        for argv in [["reply"], ["reply", "hi", "--stdin"]] {
            #expect(throws: (any Error).self) { try Elisctl.parseAsRoot(argv) }
        }
    }

    @Test(arguments: [[:], ["ELIS_SESSION_ID": ""]])
    func replyOutsideASessionFails(_ env: [String: String]) throws {
        let cmd = try parseReply(["done"])
        let error = try #require(throws: SocketClientError.self) {
            try CallerEnvironment.$values.withValue(env) {
                try cmd.makeRequest(body: "done")
            }
        }
        #expect(error.description == "elisctl reply runs inside an Elis session")
    }

    @Test func replyKeepsSessionTargetOnlyForOwnSocket() throws {
        let cmd = try Elisctl.parseAsRoot(["reply", "done"])
        let ownEnv = ["ELIS_SESSION_ID": session, "ELIS_STATE_DIR": "/tmp/elis-pane", "ELIS_SOCKET": "/tmp/elis-pane/elis.sock"]
        let ownReq = try CallerEnvironment.$values.withValue(CallerEnvironment.scoped(ownEnv, for: cmd)) {
            try #require(cmd as? Reply).makeRequest(body: "done")
        }
        #expect(ownReq.target == session)

        let otherCmd = try Elisctl.parseAsRoot(["reply", "done", "--socket", "/tmp/other/elis.sock"])
        #expect(throws: SocketClientError.self) {
            try CallerEnvironment.$values.withValue(CallerEnvironment.scoped(ownEnv, for: otherCmd)) {
                try #require(otherCmd as? Reply).makeRequest(body: "done")
            }
        }
    }

    @Test func askWaitPollsTreeWithPickBackoffAndReadsReply() throws {
        let posted = try entry(entryID, kind: .user, text: "status?", ts: 10)
        let answered = try entry(replyID, kind: .assistant, text: "all green", ts: 12)
        let askOK = ControlResponse(ok: true, result: ControlResult(assistant: ControlAssistantResult(entries: [posted])))
        let readOK = ControlResponse(ok: true, result: ControlResult(assistant: ControlAssistantResult(entries: [posted, answered])))

        let replies = [askOK]
            + Array(repeating: treeResponse(running: true), count: 12)
            + [treeResponse(running: false), readOK]
        let fake = FakeApp(replies)
        let ask = try parseAssistant(["ask", "status?", "--wait"], as: Assistant.Ask.self)

        let outcome = try ask.ask(dependencies: fake.dependencies)

        guard case .reply(let finalReply, let afterID) = outcome else {
            Issue.record("expected a reply")
            return
        }
        #expect(afterID == entryID)
        #expect(fake.requests.first?.cmd == .assistantAsk)
        #expect(fake.requests.dropFirst().dropLast().allSatisfy { $0.cmd == .tree })
        #expect(fake.requests.last?.cmd == .assistantRead)
        #expect(fake.sleeps == Array(repeating: 0.1, count: 10) + [0.5, 0.5])
        let out = Assistant.Ask.output(finalReply, json: false, after: afterID)
        #expect(out == MessageOutput(stdout: Assistant.formatEntry(answered) + "\n"))
    }

    @Test func askWithoutWaitSendsOnceAndAskWaitStopsOnError() throws {
        let posted = try entry(entryID, kind: .user, text: "hi", ts: 10)
        let askOK = ControlResponse(ok: true, result: ControlResult(assistant: ControlAssistantResult(entries: [posted])))
        let once = FakeApp([askOK])
        let noWait = try parseAssistant(["ask", "hi"], as: Assistant.Ask.self)
        guard case .reply = try noWait.ask(dependencies: once.dependencies) else {
            Issue.record("expected a reply")
            return
        }
        #expect(once.requests.count == 1)

        let refused = FakeApp([ControlResponse(ok: false, error: "assistant.ask requires text")])
        let withWait = try parseAssistant(["ask", "hi", "--wait"], as: Assistant.Ask.self)
        guard case .reply(let errReply, let afterID) = try withWait.ask(dependencies: refused.dependencies) else {
            Issue.record("expected a reply")
            return
        }
        #expect(afterID == nil)
        #expect(!errReply.response.ok)
        #expect(refused.requests.count == 1)
    }

    @Test func askWaitTimesOutWithExit124() throws {
        let posted = try entry(entryID, kind: .user, text: "slow", ts: 10)
        let askOK = ControlResponse(ok: true, result: ControlResult(assistant: ControlAssistantResult(entries: [posted])))
        let fake = FakeApp([askOK, treeResponse(running: true)])
        let ask = try parseAssistant(["ask", "slow", "--wait", "--timeout", "1"], as: Assistant.Ask.self)

        guard case .timedOut = try ask.ask(dependencies: fake.dependencies) else {
            Issue.record("expected a timeout")
            return
        }
        #expect(fake.clock == 1)
        #expect(Assistant.Ask.timeoutExitCode == 124)
    }

    @Test func humanReadLineFormatsTimestampKindSenderAndText() throws {
        let tz = TimeZone(secondsFromGMT: 0)!
        let withSender = try entry(entryID, kind: .reply, from: "claude-1", text: "tests pass", ts: 3_660)
        let withoutSender = try entry(replyID, kind: .user, from: nil, text: "hello", ts: 3_660)
        #expect(Assistant.formatEntry(withSender, timeZone: tz) == "01:01 reply @claude-1: tests pass")
        #expect(Assistant.formatEntry(withoutSender, timeZone: tz) == "01:01 user: hello")

        let readReply = try reply(ControlResult(assistant: ControlAssistantResult(entries: [withoutSender, withSender])))
        #expect(Assistant.Read.output(readReply, json: false, timeZone: tz) == MessageOutput(
            stdout: "01:01 user: hello\n01:01 reply @claude-1: tests pass\n"
        ))
        #expect(Assistant.Read.output(readReply, json: true, timeZone: tz) == MessageOutput(stdout: readReply.line + "\n"))

        let emptyReply = try reply(ControlResult(assistant: ControlAssistantResult(entries: [])))
        #expect(Assistant.Read.output(emptyReply, json: false, timeZone: tz) == MessageOutput())
    }

    @Test func sendProviderAndReplyOutputsRespectHumanAndJsonModes() throws {
        let sendReply = try reply(ControlResult(assistant: ControlAssistantResult(
            delivered: ["claude-1"],
            skipped: [AssistantSkip(handle: "codex-run", reason: "blocked")]
        )))
        #expect(Assistant.Send.output(sendReply, json: false) == MessageOutput(
            stdout: "delivered: claude-1\n",
            stderr: "skipped codex-run: blocked\n",
            failed: false
        ))
        #expect(Assistant.Send.output(sendReply, json: true) == MessageOutput(stdout: sendReply.line + "\n"))

        let nobody = try reply(ControlResult(assistant: ControlAssistantResult(
            delivered: [],
            skipped: [AssistantSkip(handle: "codex-run", reason: "blocked")]
        )))
        #expect(Assistant.Send.output(nobody, json: false) == MessageOutput(
            stderr: "skipped codex-run: blocked\nnothing was delivered\n",
            failed: true
        ))
        #expect(Assistant.Send.output(nobody, json: true) == MessageOutput(stdout: nobody.line + "\n", failed: true))

        let providerReply = try reply(ControlResult(assistant: ControlAssistantResult(
            provider: "codex",
            providers: ["claude", "codex"]
        )))
        #expect(Assistant.Provider.output(providerReply, json: false) == MessageOutput(
            stdout: "current: codex\navailable: claude, codex\n"
        ))
        #expect(Assistant.Provider.output(providerReply, json: true) == MessageOutput(stdout: providerReply.line + "\n"))

        let replyOK = try reply(ControlResult(assistant: ControlAssistantResult(
            entries: [try entry(entryID, kind: .reply, from: session, text: "done")]
        )))
        #expect(Reply.output(replyOK, json: false) == MessageOutput(stdout: "ok\n"))
        #expect(Reply.output(replyOK, json: true) == MessageOutput(stdout: replyOK.line + "\n"))

        let refused = try reply(nil, ok: false, error: "assistant.reply: unknown session bad")
        let humanErr = MessageOutput(stderr: "error: assistant.reply: unknown session bad\n", failed: true)
        #expect(Assistant.Ask.output(refused, json: false, after: nil) == humanErr)
        #expect(Assistant.Send.output(refused, json: false) == humanErr)
        #expect(Assistant.Read.output(refused, json: false) == humanErr)
        #expect(Assistant.Provider.output(refused, json: false) == humanErr)
        #expect(Reply.output(refused, json: false) == humanErr)
        #expect(Reply.output(refused, json: true) == MessageOutput(stdout: refused.line + "\n", failed: true))
    }

    @Test func eventHumanLineCarriesKindSenderAndText() {
        let tz = TimeZone(secondsFromGMT: 0)!
        let longText = String(repeating: "a", count: 100)
        let withHandle = ControlEvent(
            seq: 1, ts: 0, kind: .assistantMessage,
            payload: ControlEventPayload(from: session, kind: "reply", handle: "claude-1", text: longText)
        )
        #expect(EventFormatter.human(withHandle, timeZone: tz)
            == "00:00:00 assistant.message kind=reply from=claude-1 " + String(repeating: "a", count: 80))

        let withSessionOnly = ControlEvent(
            seq: 2, ts: 0, kind: .assistantMessage,
            payload: ControlEventPayload(from: session, kind: "reply", text: "ok")
        )
        #expect(EventFormatter.human(withSessionOnly, timeZone: tz)
            == "00:00:00 assistant.message kind=reply from=\(session) ok")

        let multiline = ControlEvent(
            seq: 4, ts: 0, kind: .assistantMessage,
            payload: ControlEventPayload(kind: "assistant", text: "one\ntwo\r\n\tthree")
        )
        #expect(EventFormatter.human(multiline, timeZone: tz)
            == "00:00:00 assistant.message kind=assistant from=- one two three")

        let noSender = ControlEvent(
            seq: 3, ts: 0, kind: .assistantMessage,
            payload: ControlEventPayload(kind: "assistant", text: "ready")
        )
        #expect(EventFormatter.human(noSender, timeZone: tz)
            == "00:00:00 assistant.message kind=assistant from=- ready")
    }
}
