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
    @ObservationIgnored var peers: () -> [AssistantPeer] = { [] }
    /// onScreen says the chat is in front of the user, so a reply arriving then is not unread.
    @ObservationIgnored var onScreen: () -> Bool = { false }
    /// mayFocus says no palette, pick or rename field in the store's window owns the keyboard.
    @ObservationIgnored var mayFocus: (AppStore) -> Bool = { _ in true }
    /// keyWindowObserver marks a missed reply seen once a chat window becomes key; the host installs it, a reinstall
    /// replaces it.
    @ObservationIgnored var keyWindowObserver: NSObjectProtocol? {
        didSet { oldValue.map(NotificationCenter.default.removeObserver) }
    }
    /// detect runs the agent detection the picker waits for.
    @ObservationIgnored var detect: @MainActor () async -> Void = {
        _ = SessionLaunchers.available
        await SessionLaunchers.settled()
    }
    private(set) var entries: [AssistantEntry] = []
    private(set) var unread = 0
    private(set) var running = false
    private(set) var provider: SessionLauncher?
    private(set) var providers: [SessionLauncher] = []
    private(set) var detected = false
    var detecting: Bool { !detected && providers.isEmpty }

    init(stateDirectory: URL?, standIn: [String]? = AssistantRunner.standInFromEnvironment()) {
        AssistantRunner.endLeftover(stateDirectory: stateDirectory)
        chat = AssistantChat(file: stateDirectory?.appendingPathComponent("assistant/chat.jsonl"))
        runner = AssistantRunner(chat: chat, stateDirectory: stateDirectory, standIn: standIn)
        runner.changed = { [weak self] in self?.refresh() }
        refresh()
    }

    func refresh() {
        if onScreen() { chat.markSeen() }
        entries = chat.entries(last: nil)
        unread = chat.unread
        running = chat.running
        provider = chat.provider
        providers = runner.providers()
    }

    /// detectProviders starts agent detection; the tree only ever reads the cached list.
    func detectProviders() async {
        await detect()
        detected = true
        refresh()
    }

    func directory() -> AssistantDirectory { AssistantDirectory(peers()) }
}
