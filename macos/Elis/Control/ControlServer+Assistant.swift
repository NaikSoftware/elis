import ElisCore
import Foundation

/// The assistant's host members: peers, the provider runner's effects and `assistant.*` events.
extension ControlServer {
    func installAssistant() {
        let model = actions.assistant
        model.runner.peers = { [weak self] in self?.assistantPeers() ?? [] }
        model.runner.emit = { [weak self] in self?.emitAssistantMessage($0) }
        model.peers = { [weak self] in self?.assistantPeers() ?? [] }
        model.perform = { [weak self] request in
            await self?.dispatch(request) ?? ControlResponse(ok: false, error: "no control server")
        }
        model.onScreen = { [weak self] in self?.assistantOnScreen() ?? false }
    }

    /// assistantOnScreen is true while a key, unminimized window shows the chat with no dashboard over it.
    func assistantOnScreen(isKey: (WindowInfo.ID) -> Bool = { WindowRegistry.shared.isKeyWindow($0) }) -> Bool {
        library.openIDs().contains { id in
            library.store(for: id)?.assistantShown == true && isKey(id) && !WindowRegistry.shared.isMinimized(id)
                && DashboardControllerRegistry.shared.controller(for: id)?.isOpen != true
        }
    }

    /// assistantPeers lists this Mac's own terminal sessions in sidebar order; a remote or page row has no shell here.
    func assistantPeers() -> [AssistantPeer]? {
        library.openIDs().flatMap { windowID -> [AssistantPeer] in
            guard library.remoteNode(for: windowID) == nil, let store = library.store(for: windowID) else { return [] }
            return store.workspaces.flatMap { workspace in
                workspace.sessions.filter { $0.remoteHost == nil && $0.content != .page }.map { session in
                    let status = session.agentIndicator.status
                    return AssistantPeer(sessionID: session.id.uuidString, window: windowID.uuidString,
                                         workspaceID: workspace.id.uuidString, workspaceName: workspace.name,
                                         name: session.displayName, agent: session.runningAgent?.rawValue,
                                         status: status == .idle ? nil : status.rawValue)
                }
            }
        }
    }

    func assistantProviders() -> [SessionLauncher]? { actions.assistant.runner.providers() }

    func assistantInput(_ entry: AssistantEntry, streamText: String) {
        emitAssistantMessage(entry)
        actions.assistant.runner.enqueue(streamText)
        actions.assistant.refresh()
    }

    func assistantSent(_ entry: AssistantEntry) {
        emitAssistantMessage(entry)
        actions.assistant.refresh()
    }

    func assistantProviderChanged(_ provider: SessionLauncher) {
        actions.assistant.runner.providerChanged(provider)
        actions.assistant.refresh()
    }

    func assistantSeen() { actions.assistant.refresh() }

    func assistantCleared() {
        actions.assistant.runner.clear()
        library.emitAppEvent(ControlEventDraft(kind: .assistantCleared))
        actions.assistant.refresh()
    }

    func showAssistant(window: String?) -> ControlResponse {
        resolver.resolvePlacementStore(window) { store in
            actions.showAssistant(in: store)
            return ControlResponse(ok: true)
        }
    }

    /// emitAssistantMessage reports an entry in its sender's window, with the sender's handle.
    func emitAssistantMessage(_ entry: AssistantEntry) {
        let peers = assistantPeers() ?? []
        let sender = entry.from.flatMap { from in peers.first { $0.sessionID == from } }
        let handle = entry.from.flatMap(AssistantDirectory(peers).handle(of:))
        library.emitAppEvent(ControlEventDraft(kind: .assistantMessage, window: sender?.window, session: entry.from,
                                               payload: ControlEventPayload(from: entry.from, kind: entry.kind.rawValue,
                                                                            handle: handle, text: entry.text)))
    }
}
