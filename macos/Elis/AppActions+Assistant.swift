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
        // nil first: the setter hides the chat only on a selection change, so a click on the old row must be one
        store.selectedSessionID = nil
        store.assistantShown = true
        assistant.chat.markSeen()
        assistant.refresh()
        NotificationCenter.default.post(name: .elisFocusAssistantComposer, object: store)
    }
}
