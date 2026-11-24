import Foundation

extension ControlDispatcher {
    /// dispatchAssistantCommand runs `assistant.*` through `AssistantCommands` and performs its effects on the host.
    func dispatchAssistantCommand(_ request: ControlRequest) async -> ControlResponse {
        let commands = AssistantCommands(chat: chat)
        // Ask the host only for what the command reads: show needs neither list, provider only the providers.
        let peers = [.assistantShow, .assistantProvider].contains(request.cmd) ? nil : actions.assistantPeers()
        let providers = request.cmd == .assistantProvider ? actions.assistantProviders() : nil
        switch commands.run(request, peers: peers, providers: providers) {
        case let .reply(response, effects):
            return perform(effects) ?? response
        case let .send(plan):
            var failures: [String: String] = [:]
            for peer in plan.targets {
                let response = await actions.typeSession(peer.sessionID, window: peer.window, options: ControlSessionTypeOptions(
                    text: plan.line + "\n", select: false, pane: nil, paneID: nil))
                if !response.ok { failures[peer.sessionID] = response.error ?? "unknown error" }
            }
            guard case let .reply(response, effects) = commands.finishSend(plan, failures: failures) else {
                preconditionFailure("finishSend always replies")
            }
            return perform(effects) ?? response
        }
    }

    /// stampAssistant adds the assistant's handles, marks and state to a host's tree; a host without it keeps its tree.
    func stampAssistant(_ response: ControlResponse) -> ControlResponse {
        guard let peers = actions.assistantPeers(), let tree = response.result?.tree else { return response }
        var stamped = response
        stamped.result?.tree = AssistantCommands(chat: chat).stamp(tree, peers: peers, providers: actions.assistantProviders())
        return stamped
    }

    /// perform returns the host's show response, which replaces the command's own.
    private func perform(_ effects: [AssistantEffect]) -> ControlResponse? {
        var shown: ControlResponse?
        for effect in effects {
            switch effect {
            case let .input(entry, streamText): actions.assistantInput(entry, streamText: streamText)
            case let .sent(entry): actions.assistantSent(entry)
            case let .providerChanged(provider): actions.assistantProviderChanged(provider)
            case .seen: actions.assistantSeen()
            case let .show(window):
                let response = actions.showAssistant(window: window)
                if response.ok { chat.markSeen() }
                shown = response
            }
        }
        return shown
    }
}
