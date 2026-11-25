import ElisCore
import Foundation
import Observation

/// AssistantModel is the chat state the assistant views observe; `refresh` copies it after every change.
@MainActor
@Observable
final class AssistantModel {
    @ObservationIgnored let chat: AssistantChat
    @ObservationIgnored let runner: AssistantRunner
    /// perform runs a control request; the control server installs it.
    @ObservationIgnored var perform: (ControlRequest) async -> ControlResponse = { request in
        ControlResponse(ok: false, error: ControlActionsUnsupported.message(request.cmd.rawValue))
    }
    private(set) var entries: [AssistantEntry] = []
    private(set) var unread = 0
    private(set) var running = false
    private(set) var provider: SessionLauncher?
    private(set) var providers: [SessionLauncher] = []

    init(stateDirectory: URL?, standIn: [String]? = AssistantRunner.standInFromEnvironment()) {
        chat = AssistantChat(file: stateDirectory?.appendingPathComponent("assistant/chat.jsonl"))
        runner = AssistantRunner(chat: chat, stateDirectory: stateDirectory, standIn: standIn)
        runner.changed = { [weak self] in self?.refresh() }
        refresh()
    }

    func refresh() {
        entries = chat.entries(last: nil)
        unread = chat.unread
        running = chat.running
        provider = chat.provider
        providers = runner.providers()
    }
}
