import ElisCore
import Foundation
#if canImport(Glibc)
import Glibc
#endif

// The assistant (shared/ElisCore's AssistantCommands) for the Qt app's GUI thread, which is the process main thread
// and so the main actor's.

@MainActor private var chat = AssistantChat()
@MainActor private var chatFile: URL?

/// onMain runs `body` on the main actor the caller's thread already is; the result goes back as a C string.
private func onMain(_ body: @MainActor () -> String) -> UnsafeMutablePointer<CChar>? {
    strdup(MainActor.assumeIsolated(body))
}

private func json<T: Encodable>(_ value: T) -> String {
    (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? #"{"error":"encoding failed"}"#
}

private func text(_ pointer: UnsafePointer<CChar>) -> String { String(cString: pointer) }

private func decoded<T: Decodable>(_ type: T.Type, _ json: UnsafePointer<CChar>) -> T? {
    try? JSONDecoder().decode(type, from: Data(text(json).utf8))
}

/// Opens the chat at `<stateDir>/assistant/chat.jsonl`; the same path again keeps the open chat.
@_cdecl("elis_assistant_open")
public func elisAssistantOpen(_ stateDir: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    let file = URL(fileURLWithPath: text(stateDir)).appendingPathComponent("assistant/chat.jsonl")
    return onMain {
        if file != chatFile {
            chat = AssistantChat(file: file)
            chatFile = file
        }
        return "{}"
    }
}

private struct Effect: Encodable {
    let type: String
    var entry: AssistantEntry?
    var streamText: String?
    var provider: String?
    var window: String?

    init(_ effect: AssistantEffect) {
        switch effect {
        case let .input(entry, streamText):
            type = "input"
            self.entry = entry
            self.streamText = streamText
        case let .sent(entry):
            type = "sent"
            self.entry = entry
        case let .providerChanged(provider):
            type = "providerChanged"
            self.provider = provider.rawValue
        case let .show(window):
            type = "show"
            self.window = window
        }
    }
}

private struct Step: Encodable {
    var reply: ControlResponse?
    var effects: [Effect]?
    var plan: AssistantSendPlan?

    init(_ step: AssistantStep) {
        switch step {
        case let .reply(response, effects):
            reply = response
            self.effects = effects.map(Effect.init)
        case let .send(plan):
            self.plan = plan
        }
    }
}

private func refused(_ message: String) -> String {
    json(Step(.reply(ControlResponse(ok: false, error: message), effects: [])))
}

private let commands: Set<Command> = [.assistantShow, .assistantProvider, .assistantAsk, .assistantSend, .assistantReply,
                                      .assistantRead]

private func providers(_ json: UnsafePointer<CChar>) -> [SessionLauncher]? {
    decoded([String].self, json)?.compactMap(SessionLauncher.init(rawValue:))
}

@_cdecl("elis_assistant_run")
public func elisAssistantRun(_ requestJSON: UnsafePointer<CChar>, _ peersJSON: UnsafePointer<CChar>,
                             _ providersJSON: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    let request = decoded(ControlRequest.self, requestJSON)
    let peers = decoded([AssistantPeer].self, peersJSON)
    let providers = providers(providersJSON)
    return onMain {
        guard let request else { return refused("invalid request") }
        guard commands.contains(request.cmd) else { return refused("not an assistant command: \(request.cmd.rawValue)") }
        return json(Step(AssistantCommands(chat: chat).run(request, peers: peers, providers: providers)))
    }
}

@_cdecl("elis_assistant_finish_send")
public func elisAssistantFinishSend(_ planJSON: UnsafePointer<CChar>, _ failuresJSON: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    let plan = decoded(AssistantSendPlan.self, planJSON)
    let failures = decoded([String: String].self, failuresJSON) ?? [:]
    return onMain {
        guard let plan else { return refused("invalid plan") }
        return json(Step(AssistantCommands(chat: chat).finishSend(plan, failures: failures)))
    }
}

// The host's tree is its own shape, not ControlTree, so the core's handles, marks and node are laid onto it by id.
@_cdecl("elis_assistant_stamp")
public func elisAssistantStamp(_ treeJSON: UnsafePointer<CChar>, _ peersJSON: UnsafePointer<CChar>,
                               _ providersJSON: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    let raw = text(treeJSON)
    let peers = decoded([AssistantPeer].self, peersJSON)
    let providers = providers(providersJSON)
    return onMain {
        guard let peers, var tree = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
              let node = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(AssistantCommands(chat: chat).node(providers: providers)))
        else { return raw }
        let directory = AssistantDirectory(peers)
        if let workspaces = tree["workspaces"] as? [[String: Any]] {
            tree["workspaces"] = workspaces.map { workspace in
                var workspace = workspace
                workspace["handle"] = (workspace["id"] as? String).flatMap(directory.workspaceHandle(of:))
                if let sessions = workspace["sessions"] as? [[String: Any]] {
                    workspace["sessions"] = sessions.map { session in
                        var session = session
                        let id = session["id"] as? String ?? ""
                        session["handle"] = directory.handle(of: id)
                        session["assistantMark"] = chat.marks[id]?.rawValue
                        return session
                    }
                }
                return workspace
            }
        }
        tree["assistant"] = node
        return (try? JSONSerialization.data(withJSONObject: tree)).map { String(decoding: $0, as: UTF8.self) } ?? raw
    }
}

@_cdecl("elis_assistant_turn_ended")
public func elisAssistantTurnEnded() {
    MainActor.assumeIsolated { chat.turnEnded() }
}

@_cdecl("elis_assistant_provider_failed")
public func elisAssistantProviderFailed(_ message: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    let message = text(message)
    return onMain {
        chat.providerFailed(message, now: Date().timeIntervalSince1970)
        return json(chat.entries(last: 1).first)
    }
}

@_cdecl("elis_assistant_mark_seen")
public func elisAssistantMarkSeen() {
    MainActor.assumeIsolated { chat.markSeen() }
}

@_cdecl("elis_assistant_append_assistant")
public func elisAssistantAppendAssistant(_ reply: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    let reply = text(reply)
    return onMain { json(chat.append(.assistant, text: reply, now: Date().timeIntervalSince1970)) }
}

private func launcher(_ name: UnsafePointer<CChar>) -> SessionLauncher? { SessionLauncher(rawValue: text(name)) }

private func prompt(_ peersJSON: UnsafePointer<CChar>) -> String {
    AssistantPrompt.system(AssistantDirectory(decoded([AssistantPeer].self, peersJSON) ?? []))
}

@_cdecl("elis_assistant_launch")
public func elisAssistantLaunch(_ provider: UnsafePointer<CChar>, _ peersJSON: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    struct Launch: Encodable {
        let argv: [String]
        let mode: String
        let environment: [String: String]
        let preamble: String?
    }
    let name = text(provider)
    let prompt = prompt(peersJSON)
    return onMain {
        guard let p = SessionLauncher(rawValue: name) else { return json(["error": "unknown provider \(name)"]) }
        let launch = AssistantProvider.launch(p, prompt: prompt, resume: chat.resume[p])
        return json(Launch(argv: launch.argv, mode: launch.mode == .stream ? "stream" : "perInput", environment: launch.environment,
                           preamble: launch.preamble))
    }
}

@_cdecl("elis_assistant_turn_argv")
public func elisAssistantTurnArgv(_ provider: UnsafePointer<CChar>, _ input: UnsafePointer<CChar>,
                                  _ peersJSON: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    let p = launcher(provider)
    let input = text(input)
    let prompt = prompt(peersJSON)
    return onMain {
        guard let p else { return "[]" }
        return json(AssistantProvider.turn(p, input: input, prompt: prompt, resume: chat.resume[p]))
    }
}

@_cdecl("elis_assistant_encode")
public func elisAssistantEncode(_ provider: UnsafePointer<CChar>, _ input: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    strdup(launcher(provider).map { AssistantStream.encode($0, text: text(input)) } ?? "")
}

@_cdecl("elis_assistant_decode")
public func elisAssistantDecode(_ provider: UnsafePointer<CChar>, _ line: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    struct Event: Encodable {
        var text: String?
        var conversation: String?
        var turnEnded: Bool?
        var error: String?
    }
    let p = launcher(provider)
    let line = text(line)
    return onMain {
        guard let p else { return "[]" }
        return json(AssistantStream.decode(p, line: line).map { event -> Event in
            switch event {
            case let .text(text): return Event(text: text)
            case let .conversation(id):
                chat.resume[p] = id
                return Event(conversation: id)
            case let .turnEnded(error): return Event(turnEnded: true, error: error)
            }
        })
    }
}

@_cdecl("elis_assistant_recap")
public func elisAssistantRecap() -> UnsafeMutablePointer<CChar>? {
    onMain { AssistantPrompt.inline(chat.entries(last: 50)) }
}
