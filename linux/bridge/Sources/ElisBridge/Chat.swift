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

// Pointers are read into Strings before onMain: its closure may not capture them.
private func decoded<T: Decodable>(_ type: T.Type, _ json: String) -> T? {
    try? JSONDecoder().decode(type, from: Data(json.utf8))
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
        case .seen:
            type = "seen"
        case .cleared:
            type = "cleared"
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

private func failed(_ message: String) -> String { json(["error": message]) }

private let commands: Set<Command> = [.assistantShow, .assistantProvider, .assistantAsk, .assistantSend, .assistantReply,
                                      .assistantRead, .assistantSeen, .assistantClear]

/// Listed is a list the host passes, where the JSON text `null` means it cannot list it; anything else that does not
/// decode fails the init.
private struct Listed<T: Decodable> {
    let value: T?

    init?(_ type: T.Type, _ json: String) {
        if json == "null" {
            value = nil
        } else if let value = decoded(type, json) {
            self.value = value
        } else {
            return nil
        }
    }
}

private func launchers(_ names: [String]?) -> [SessionLauncher]? { names?.compactMap(SessionLauncher.init(rawValue:)) }

@_cdecl("elis_assistant_run")
public func elisAssistantRun(_ requestJSON: UnsafePointer<CChar>, _ peersJSON: UnsafePointer<CChar>,
                             _ providersJSON: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    let (request, peers, providers) = (text(requestJSON), text(peersJSON), text(providersJSON))
    return onMain {
        guard let request = decoded(ControlRequest.self, request) else { return refused("invalid request") }
        guard commands.contains(request.cmd) else { return refused("not an assistant command: \(request.cmd.rawValue)") }
        guard let peers = Listed([AssistantPeer].self, peers) else { return refused("invalid peers") }
        guard let providers = Listed([String].self, providers) else { return refused("invalid providers") }
        return json(Step(AssistantCommands(chat: chat).run(request, peers: peers.value, providers: launchers(providers.value))))
    }
}

@_cdecl("elis_assistant_finish_send")
public func elisAssistantFinishSend(_ planJSON: UnsafePointer<CChar>, _ failuresJSON: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    let (plan, failures) = (text(planJSON), text(failuresJSON))
    return onMain {
        guard let plan = decoded(AssistantSendPlan.self, plan) else { return refused("invalid plan") }
        guard let failures = decoded([String: String].self, failures) else { return refused("invalid failures") }
        return json(Step(AssistantCommands(chat: chat).finishSend(plan, failures: failures)))
    }
}

@_cdecl("elis_assistant_stamp")
public func elisAssistantStamp(_ treeJSON: UnsafePointer<CChar>, _ peersJSON: UnsafePointer<CChar>,
                               _ providersJSON: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    let (tree, peers, providers) = (text(treeJSON), text(peersJSON), text(providersJSON))
    return onMain {
        guard let tree = (try? JSONSerialization.jsonObject(with: Data(tree.utf8))) as? [String: Any] else {
            return failed("invalid tree")
        }
        guard let peers = Listed([AssistantPeer].self, peers) else { return failed("invalid peers") }
        guard let providers = Listed([String].self, providers) else { return failed("invalid providers") }
        guard let stamped = try? AssistantCommands(chat: chat).stampJSON(tree, peers: peers.value, providers: launchers(providers.value)),
              let data = try? JSONSerialization.data(withJSONObject: stamped)
        else { return failed("encoding failed") }
        return String(decoding: data, as: UTF8.self)
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

@_cdecl("elis_assistant_turn_failed")
public func elisAssistantTurnFailed(_ message: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    let message = text(message)
    return onMain { json(chat.turnFailed(message, now: Date().timeIntervalSince1970)) }
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

/// provider is a name the assistant picker offers: never `terminal`.
private func provider(_ name: String) -> SessionLauncher? {
    SessionLauncher(rawValue: name).flatMap { AssistantProvider.choices([$0]).first }
}

private func prompt(_ peers: [AssistantPeer]?) -> String { AssistantPrompt.system(AssistantDirectory(peers ?? [])) }

@_cdecl("elis_assistant_launch")
public func elisAssistantLaunch(_ name: UnsafePointer<CChar>, _ peersJSON: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    struct Launch: Encodable {
        let argv: [String]
        let mode: String
        let environment: [String: String]
        let preamble: String?
    }
    let (name, peers) = (text(name), text(peersJSON))
    return onMain {
        guard let p = provider(name) else { return failed("unknown provider \(name)") }
        guard let peers = Listed([AssistantPeer].self, peers) else { return failed("invalid peers") }
        let launch = AssistantProvider.launch(p, prompt: prompt(peers.value), resume: chat.resume[p])
        return json(Launch(argv: launch.argv, mode: launch.mode == .stream ? "stream" : "perInput", environment: launch.environment,
                           preamble: launch.preamble))
    }
}

@_cdecl("elis_assistant_turn_argv")
public func elisAssistantTurnArgv(_ name: UnsafePointer<CChar>, _ input: UnsafePointer<CChar>,
                                  _ peersJSON: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    let (name, input, peers) = (text(name), text(input), text(peersJSON))
    return onMain {
        guard let p = provider(name) else { return failed("unknown provider \(name)") }
        guard let peers = Listed([AssistantPeer].self, peers) else { return failed("invalid peers") }
        return json(AssistantProvider.turn(p, input: input, prompt: prompt(peers.value), resume: chat.resume[p]))
    }
}

@_cdecl("elis_assistant_encode")
public func elisAssistantEncode(_ name: UnsafePointer<CChar>, _ input: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    strdup(provider(text(name)).map { AssistantStream.encode($0, text: text(input)) } ?? "")
}

@_cdecl("elis_assistant_decode")
public func elisAssistantDecode(_ name: UnsafePointer<CChar>, _ line: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    struct Event: Encodable {
        var text: String?
        var conversation: String?
        var turnEnded: Bool?
        var error: String?
    }
    let (name, line) = (text(name), text(line))
    return onMain {
        guard let p = provider(name) else { return failed("unknown provider \(name)") }
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

@_cdecl("elis_assistant_resume")
public func elisAssistantResume(_ name: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    let name = text(name)
    return onMain { provider(name).flatMap { chat.resume[$0] } ?? "" }
}

@_cdecl("elis_assistant_forget_resume")
public func elisAssistantForgetResume(_ name: UnsafePointer<CChar>) {
    let name = text(name)
    MainActor.assumeIsolated {
        if let p = provider(name) { chat.resume[p] = nil }
    }
}

@_cdecl("elis_assistant_recap")
public func elisAssistantRecap() -> UnsafeMutablePointer<CChar>? {
    onMain { AssistantPrompt.inline(chat.settledEntries(last: 50)) }
}
