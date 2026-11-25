import ElisCore
import Foundation
import Observation

/// Keeps the Mac and its display from idle sleep while `WindowLibrary.hasActiveLocalAgent` and Settings' keep-awake
/// are on. The activity ends with the process, so a crash leaves none behind.
/// Observation re-arms like `DockBadgeController`'s, and the same unobserved store drops poke `refresh()`.
@MainActor
final class KeepAwakeController {
    static let shared = KeepAwakeController()

    weak var library: WindowLibrary?
    weak var settingsModel: SettingsModel?
    private var activity: NSObjectProtocol?
    private var refreshScheduled = false

    func refresh() { apply() }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshScheduled = false
            self?.apply()
        }
    }

    private func apply() {
        let wanted = withObservationTracking {
            (settingsModel?.settings.keepAwake ?? false) && (library?.hasActiveLocalAgent ?? false)
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.scheduleRefresh() } }
        }
        if wanted, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled], reason: "An agent is working")
        } else if !wanted, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}
