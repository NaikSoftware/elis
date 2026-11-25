import ElisCore
import Foundation

extension Notification.Name {
    /// The chat view focuses its composer; `object` is the window's store.
    static let elisFocusAssistantComposer = Notification.Name("elisFocusAssistantComposer")
}

extension AppActions {
    func showAssistant(in store: AppStore) {
        if let dashboard = DashboardControllerRegistry.shared.controller(for: library.windowID(for: store)), dashboard.isOpen {
            dashboard.close()
        }
        // nil, so a later click on the previously selected row is a change that hides the chat
        store.selectedSessionID = nil
        store.assistantShown = true
        assistant.chat.markSeen()
        assistant.refresh()
        NotificationCenter.default.post(name: .elisFocusAssistantComposer, object: store)
    }
}
