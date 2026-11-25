import ElisCore
import Foundation

extension Notification.Name {
    /// The chat view focuses its composer; `object` is the window's store.
    static let elisFocusAssistantComposer = Notification.Name("elisFocusAssistantComposer")
}

extension AppActions {
    func showAssistant(in store: AppStore) {
        // the chat replaces whatever covers the window
        let windowID = library.windowID(for: store)
        if let dashboard = DashboardControllerRegistry.shared.controller(for: windowID), dashboard.isOpen { dashboard.close() }
        TerminalZoomRegistry.shared.controller(for: windowID)?.clear()
        // nil, so a later click on the previously selected row is a change that hides the chat
        store.selectedSessionID = nil
        store.assistantShown = true
        assistant.chat.markSeen()
        assistant.refresh()
        NotificationCenter.default.post(name: .elisFocusAssistantComposer, object: store)
    }

    /// Whether the composer may take the keyboard: the gates `focusActiveSession` applies, in the composer's window.
    func composerMayTakeFocus(in store: AppStore) -> Bool {
        let windowID = library.windowID(for: store)
        if windowID == library.activeWindowID, renamePending || palette?.mode != nil { return false }
        return !pickActive(for: windowID) && !quickTerminal.holdsKey
            && DashboardControllerRegistry.shared.controller(for: windowID)?.isOpen != true
            && TerminalZoomRegistry.shared.controller(for: windowID)?.target == nil
    }
}
