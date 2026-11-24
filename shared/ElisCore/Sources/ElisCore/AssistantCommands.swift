import Foundation

public enum AssistantStep: Sendable {
    case reply(ControlResponse, effects: [AssistantEffect])
    /// send asks the host to type `line` into each target, then call `finishSend`.
    case send(AssistantSendPlan)
}

public enum AssistantEffect: Sendable, Equatable {
    case input(AssistantEntry, streamText: String)
    case sent(AssistantEntry)
    case providerChanged(SessionLauncher)
    /// show is the host's to perform; it marks the chat seen only when its show succeeded.
    case show(window: String?)
    /// seen follows the chat already marked seen: the host repaints its unread badge.
    case seen
}

public struct AssistantSendPlan: Sendable, Codable, Equatable {
    public var targets: [AssistantPeer]
    public var line: String
    public var body: String
    public var cut: Bool
    public var skipped: [AssistantSkip]
    public var skippedIDs: [String]
    /// handles maps a target's session id to the handle the result reports.
    public var handles: [String: String]
}

/// AssistantCommands runs `assistant.*` against the chat without waiting on the host, so a synchronous host can
/// drive it; the host lists peers and providers, performs the effects and types the send plan.
@MainActor
public struct AssistantCommands {
    let chat: AssistantChat

    public init(chat: AssistantChat) {
        self.chat = chat
    }

    public func run(_ request: ControlRequest, peers: [AssistantPeer]?, providers: [SessionLauncher]?) -> AssistantStep {
        let args = request.args ?? ControlArgs()
        let unsupported = AssistantStep.reply(ControlResponse(ok: false, error: ControlActionsUnsupported.message(request.cmd.rawValue)),
                                              effects: [])
        switch request.cmd {
        case .assistantShow:
            return .reply(ControlResponse(ok: true), effects: [.show(window: args.window)])
        case .assistantProvider:
            guard let providers else { return unsupported }
            return provider(args, available: AssistantProvider.choices(providers))
        default:
            break
        }
        guard let peers else { return unsupported }
        switch request.cmd {
        case .assistantAsk: return ask(args)
        case .assistantSend: return send(args, directory: AssistantDirectory(peers))
        case .assistantReply: return reply(request.target, args, directory: AssistantDirectory(peers))
        case .assistantSeen:
            chat.markSeen()
            return .reply(ControlResponse(ok: true), effects: [.seen])
        case .assistantRead:
            if let last = args.last, last < 1 { return failure("assistant.read: --last must be positive") }
            return success(ControlAssistantResult(entries: chat.entries(last: args.last)))
        default: preconditionFailure("unexpected assistant command: \(request.cmd.rawValue)")
        }
    }

    /// finishSend records a send once the host typed its plan; `failures` maps a session id to its typing error.
    public func finishSend(_ plan: AssistantSendPlan, failures: [String: String]) -> AssistantStep {
        var delivered: [AssistantPeer] = []
        var skipped = plan.skipped
        var skippedIDs = plan.skippedIDs
        for peer in plan.targets {
            if let error = failures[peer.sessionID] {
                skipped.append(AssistantSkip(handle: plan.handles[peer.sessionID] ?? peer.sessionID, reason: "failed: \(error)"))
                skippedIDs.append(peer.sessionID)
            } else {
                delivered.append(peer)
            }
        }
        var sent: AssistantEntry?
        if !delivered.isEmpty {
            sent = chat.append(.sent, text: plan.body, to: delivered.map(\.sessionID), now: Date().timeIntervalSince1970)
        }
        chat.markSkipped(skippedIDs)
        let result = ControlAssistantResult(entries: sent.map { [$0] }, delivered: delivered.map { plan.handles[$0.sessionID] ?? $0.sessionID },
                                            deliveredIDs: delivered.map(\.sessionID), skipped: skipped, cut: plan.cut ? true : nil)
        return .reply(ControlResponse(ok: true, result: ControlResult(assistant: result)), effects: sent.map { [.sent($0)] } ?? [])
    }

    /// stamp adds the assistant's handles, marks and state to a host's tree; a host without it keeps its tree.
    public func stamp(_ tree: ControlTree, peers: [AssistantPeer]?, providers: [SessionLauncher]?) -> ControlTree {
        guard let peers else { return tree }
        var tree = tree
        let directory = AssistantDirectory(peers)
        for w in tree.workspaces.indices {
            tree.workspaces[w].handle = directory.workspaceHandle(of: tree.workspaces[w].id)
            for s in tree.workspaces[w].sessions.indices {
                let added = sessionStamp(tree.workspaces[w].sessions[s].id, directory)
                tree.workspaces[w].sessions[s].handle = added.handle
                tree.workspaces[w].sessions[s].assistantMark = added.assistantMark
            }
        }
        tree.assistant = node(providers: providers)
        return tree
    }

    /// stampJSON is `stamp` for a host whose tree is JSON of its own shape: the same keys laid on by id, every other key kept.
    public func stampJSON(_ tree: [String: Any], peers: [AssistantPeer]?, providers: [SessionLauncher]?) throws -> [String: Any] {
        guard let peers else { return tree }
        var tree = tree
        let directory = AssistantDirectory(peers)
        if let workspaces = tree["workspaces"] as? [[String: Any]] {
            tree["workspaces"] = workspaces.map { workspace in
                var workspace = workspace
                workspace["handle"] = (workspace["id"] as? String).flatMap(directory.workspaceHandle(of:))
                if let sessions = workspace["sessions"] as? [[String: Any]] {
                    workspace["sessions"] = sessions.map { session in
                        var session = session
                        let added = sessionStamp(session["id"] as? String ?? "", directory)
                        session["handle"] = added.handle
                        session["assistantMark"] = added.assistantMark
                        return session
                    }
                }
                return workspace
            }
        }
        tree["assistant"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(node(providers: providers)))
        return tree
    }

    private func sessionStamp(_ id: String, _ directory: AssistantDirectory) -> (handle: String?, assistantMark: String?) {
        (directory.handle(of: id), chat.marks[id]?.rawValue)
    }

    private func node(providers: [SessionLauncher]?) -> ControlAssistantNode {
        ControlAssistantNode(provider: chat.provider?.rawValue, providers: AssistantProvider.choices(providers ?? []).map(\.rawValue),
                             running: chat.running, unread: chat.unread)
    }

    private func ask(_ args: ControlArgs) -> AssistantStep {
        guard let text = args.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return failure("assistant.ask requires text")
        }
        let entry = chat.append(.user, text: text, now: Date().timeIntervalSince1970)
        chat.inputQueued()
        return success(ControlAssistantResult(entries: [entry]), effects: [.input(entry, streamText: text)])
    }

    private func send(_ args: ControlArgs, directory: AssistantDirectory) -> AssistantStep {
        guard let tags = args.recipients, !tags.isEmpty else { return failure("assistant.send requires --to") }
        let typed: AssistantLine.Typed
        let delivery: AssistantDelivery
        do { typed = try AssistantLine.typed(args.text ?? "") } catch { return failure(error.message) }
        do { delivery = try AssistantTargets.resolve(tags, in: directory) } catch { return failure(error.message) }
        let skippedIDs = delivery.skipped.compactMap { skip in
            directory.peers.first { directory.handle(of: $0.sessionID) == skip.handle }?.sessionID
        }
        let handles = Dictionary(delivery.targets.map { ($0.sessionID, handle($0, in: directory)) }) { first, _ in first }
        return .send(AssistantSendPlan(targets: delivery.targets, line: typed.line, body: typed.body, cut: typed.cut,
                                       skipped: delivery.skipped, skippedIDs: skippedIDs, handles: handles))
    }

    private func reply(_ target: String?, _ args: ControlArgs, directory: AssistantDirectory) -> AssistantStep {
        guard let target else { return failure("assistant.reply requires a session") }
        guard let text = args.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return failure("assistant.reply requires text")
        }
        guard let peer = replySender(target, in: directory.peers) else {
            return failure("assistant.reply: unknown session \(target)")
        }
        let stored = chat.append(.reply, text: text, from: peer.sessionID, now: Date().timeIntervalSince1970)
        chat.inputQueued()
        return success(ControlAssistantResult(entries: [stored]),
                       effects: [.input(stored, streamText: "[reply from @\(handle(peer, in: directory)) \(peer.sessionID)] \(text)")])
    }

    private func provider(_ args: ControlArgs, available: [SessionLauncher]) -> AssistantStep {
        let names = available.map(\.rawValue)
        guard let name = args.provider else {
            return success(ControlAssistantResult(provider: chat.provider?.rawValue, providers: names))
        }
        guard let provider = SessionLauncher(rawValue: name), available.contains(provider) else {
            return failure("unknown provider \(name); available: \(names.joined(separator: ", "))")
        }
        chat.provider = provider
        return success(ControlAssistantResult(provider: name, providers: names), effects: [.providerChanged(provider)])
    }

    /// replySender matches a session id exactly, else a unique case-insensitive prefix of at least 3 characters.
    private func replySender(_ target: String, in peers: [AssistantPeer]) -> AssistantPeer? {
        if let exact = peers.first(where: { $0.sessionID == target }) { return exact }
        guard target.count >= 3 else { return nil }
        let prefix = target.lowercased()
        let matches = peers.filter { $0.sessionID.lowercased().hasPrefix(prefix) }
        return matches.count == 1 ? matches[0] : nil
    }

    private func handle(_ peer: AssistantPeer, in directory: AssistantDirectory) -> String {
        directory.handle(of: peer.sessionID) ?? peer.sessionID
    }

    private func success(_ result: ControlAssistantResult, effects: [AssistantEffect] = []) -> AssistantStep {
        .reply(ControlResponse(ok: true, result: ControlResult(assistant: result)), effects: effects)
    }

    private func failure(_ message: String) -> AssistantStep {
        .reply(ControlResponse(ok: false, error: message), effects: [])
    }
}
