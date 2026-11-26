import AppKit
import ElisCore

/// CIStatusLine runs the app's `CIPoller` and shows a session row's CI menu.
@MainActor
enum CIStatusLine {
    private static var poller: CIPoller?
    private(set) static weak var menu: NSMenu?
    private static weak var menuSession: Session?
    private static let opener = URLOpener()

    static func start(library: WindowLibrary) {
        let poller = CIPoller(
            sessions: { [weak library] in library?.openStores().flatMap { $0.workspaces.flatMap(\.sessions) } ?? [] },
            // Off polls nothing, and Flagged only what the flagged view can show
            include: { session in
                switch GhosttyApp.shared.sessionInfoDisplay {
                case .off: false
                case .flagged: session.flagged
                case .always: true
                }
            },
            apply: { [weak library] session, ci in library?.store(forSession: session.id)?.setCI(ci, forSession: session.id) })
        poller.start()
        self.poller = poller
    }

    /// showMenu pops the session's CI menu under the line at its leading edge; it returns once the menu closes.
    static func showMenu(for session: Session, from field: SidebarInfoField) {
        guard let ci = session.effectiveCI, !ci.isEmpty else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.items = menuItems(for: ci)
        self.menu = menu
        menuSession = session
        closeWhenTheLineGoes(ObjectIdentifier(menu))
        menu.popUp(positioning: nil, at: NSPoint(x: field.bounds.minX, y: field.isFlipped ? field.bounds.maxY : field.bounds.minY), in: field)
        self.menu = nil
    }

    /// menuItems lists the PR and its reviews, then every run by state, each link opening its GitHub page.
    static func menuItems(for ci: CIStatus) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if let pr = ci.pr {
            items.append(link(title: "#\(pr.number) \(pr.title)", url: pr.url))
            let reviews = [("Approved", pr.approved), ("Changes requested", pr.changesRequested)]
                .filter { !$0.1.isEmpty }.map { "\($0.0): \($0.1.joined(separator: ", "))" }
            for title in reviews.isEmpty ? ["No reviews yet"] : reviews {
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.isEnabled = false
                items.append(item)
            }
            if !ci.runs.isEmpty { items.append(.separator()) }
        }
        for state in [CIRunState.failed, .running, .passed, .skipped] {
            for run in ci.runs where run.state == state {
                let item = link(title: run.workflow, url: run.url)
                item.image = NSImage(systemSymbolName: symbol(state), accessibilityDescription: description(state))?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .medium)
                        .applying(.init(paletteColors: [color(state)])))
                item.keepsImageVisible()
                if state == .skipped {
                    item.attributedTitle = NSAttributedString(string: run.workflow, attributes: [.font: NSFont.menuFont(ofSize: 0),
                                                                                              .foregroundColor: NSColor.secondaryLabelColor])
                }
                items.append(item)
            }
        }
        return items
    }

    private static func link(title: String, url: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(URLOpener.open(_:)), keyEquivalent: "")
        item.target = opener
        item.representedObject = url
        return item
    }

    /// closeWhenTheLineGoes cancels the open menu once its session's line goes, as the row's own gate decides.
    private static func closeWhenTheLineGoes(_ id: ObjectIdentifier) {
        guard let menu, ObjectIdentifier(menu) == id, let session = menuSession else { return }
        guard let ci = session.effectiveCI, !ci.isEmpty else { return menu.cancelTracking() }
        withObservationTracking { _ = session.effectiveCI } onChange: {
            // onChange runs before the new value lands
            DispatchQueue.main.async { MainActor.assumeIsolated { closeWhenTheLineGoes(id) } }
        }
    }

    private static func symbol(_ state: CIRunState) -> String {
        switch state {
        case .failed: "xmark"
        case .running: "clock"
        case .passed: "checkmark"
        case .skipped: "minus"
        }
    }

    private static func description(_ state: CIRunState) -> String {
        switch state {
        case .failed: "Failed"
        case .running: "Running"
        case .passed: "Passed"
        case .skipped: "Skipped"
        }
    }

    private static func color(_ state: CIRunState) -> NSColor {
        switch state {
        case .failed: .tint(.red)
        case .running: .tint(.yellow)
        case .passed: .tint(.green)
        case .skipped: .secondaryLabelColor
        }
    }
}

/// URLOpener opens a menu item's `https` URL; any other scheme does nothing.
@MainActor
private final class URLOpener: NSObject {
    @objc func open(_ item: NSMenuItem) {
        guard let string = item.representedObject as? String, let url = URL(string: string), url.scheme == "https" else { return }
        NSWorkspace.shared.open(url)
    }
}
