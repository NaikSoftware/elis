import Foundation

extension ControlDispatcher {
    /// dispatchAssistantCommand runs `assistant.*` against the chat; the host lists peers and providers, types into
    /// sessions, feeds the assistant's stream and shows the chat.
    func dispatchAssistantCommand(_ request: ControlRequest) async -> ControlResponse {
        let args = request.args ?? ControlArgs()
        let unsupported = ControlResponse(ok: false, error: ControlActionsUnsupported.message(request.cmd.rawValue))
        switch request.cmd {
        case .assistantShow:
            let response = actions.showAssistant(window: args.window)
            if response.ok { chat.markSeen() }
            return response
        case .assistantProvider:
            guard let available = actions.assistantProviders() else { return unsupported }
            return dispatchAssistantProvider(args, available: AssistantProvider.choices(available))
        default:
            break
        }
        guard let peers = actions.assistantPeers() else { return unsupported }
        switch request.cmd {
        case .assistantAsk: return dispatchAssistantAsk(args)
        case .assistantSend: return await dispatchAssistantSend(args, directory: AssistantDirectory(peers))
        case .assistantReply: return dispatchAssistantReply(request.target, args, directory: AssistantDirectory(peers))
        case .assistantRead:
            if let last = args.last, last < 1 { return assistantFailure("assistant.read: --last must be positive") }
            return assistantSuccess(ControlAssistantResult(entries: chat.entries(last: args.last)))
        default: preconditionFailure("unexpected assistant command: \(request.cmd.rawValue)")
        }
    }

    private func dispatchAssistantAsk(_ args: ControlArgs) -> ControlResponse {
        guard let text = args.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return assistantFailure("assistant.ask requires text")
        }
        let entry = chat.append(.user, text: text, now: Date().timeIntervalSince1970)
        chat.inputQueued()
        actions.assistantInput(entry, streamText: text)
        return assistantSuccess(ControlAssistantResult(entries: [entry]))
    }

    private func dispatchAssistantSend(_ args: ControlArgs, directory: AssistantDirectory) async -> ControlResponse {
        guard let tags = args.recipients, !tags.isEmpty else { return assistantFailure("assistant.send requires --to") }
        let text = args.text ?? ""
        let line: String
        let delivery: AssistantDelivery
        do { line = try AssistantLine.make(text) } catch { return assistantFailure(error.message) }
        do { delivery = try AssistantTargets.resolve(tags, in: directory) } catch { return assistantFailure(error.message) }

        var delivered: [AssistantPeer] = []
        var skipped = delivery.skipped
        var skippedIDs = delivery.skipped.compactMap { skip in
            directory.peers.first { directory.handle(of: $0.sessionID) == skip.handle }?.sessionID
        }
        for peer in delivery.targets {
            let response = await actions.typeSession(peer.sessionID, window: peer.window, options: ControlSessionTypeOptions(
                text: line + "\n", select: false, pane: nil, paneID: nil))
            if response.ok {
                delivered.append(peer)
            } else {
                skipped.append(AssistantSkip(handle: handle(peer, in: directory), reason: "failed: \(response.error ?? "unknown error")"))
                skippedIDs.append(peer.sessionID)
            }
        }
        var sent: AssistantEntry?
        if !delivered.isEmpty {
            sent = chat.append(.sent, text: text, to: delivered.map(\.sessionID), now: Date().timeIntervalSince1970)
        }
        chat.markSkipped(skippedIDs)
        if let sent { actions.assistantSent(sent) }
        return assistantSuccess(ControlAssistantResult(entries: sent.map { [$0] }, delivered: delivered.map { handle($0, in: directory) },
                                                       skipped: skipped))
    }

    private func dispatchAssistantReply(_ target: String?, _ args: ControlArgs, directory: AssistantDirectory) -> ControlResponse {
        guard let target else { return assistantFailure("assistant.reply requires a session") }
        guard let text = args.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return assistantFailure("assistant.reply requires text")
        }
        guard let peer = replySender(target, in: directory.peers) else {
            return assistantFailure("assistant.reply: unknown session \(target)")
        }
        let stored = chat.append(.reply, text: text, from: peer.sessionID, now: Date().timeIntervalSince1970)
        chat.inputQueued()
        actions.assistantInput(stored, streamText: "[reply from @\(handle(peer, in: directory))] \(text)")
        return assistantSuccess(ControlAssistantResult(entries: [stored]))
    }

    private func dispatchAssistantProvider(_ args: ControlArgs, available: [SessionLauncher]) -> ControlResponse {
        let names = available.map(\.rawValue)
        guard let name = args.provider else {
            return assistantSuccess(ControlAssistantResult(provider: chat.provider?.rawValue, providers: names))
        }
        guard let provider = SessionLauncher(rawValue: name), available.contains(provider) else {
            return assistantFailure("unknown provider \(name); available: \(names.joined(separator: ", "))")
        }
        chat.provider = provider
        actions.assistantProviderChanged(provider)
        return assistantSuccess(ControlAssistantResult(provider: name, providers: names))
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

    private func assistantSuccess(_ result: ControlAssistantResult) -> ControlResponse {
        ControlResponse(ok: true, result: ControlResult(assistant: result))
    }

    private func assistantFailure(_ message: String) -> ControlResponse {
        ControlResponse(ok: false, error: message)
    }
}
