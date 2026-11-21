import AppKit
import ElisCore
import SwiftUI

/// CIStatusLine runs the app's `CIPoller` and shows a session row's CI panel.
@MainActor
enum CIStatusLine {
    private static var poller: CIPoller?
    private static weak var panel: NSPopover?

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

    static func showPanel(for session: Session, from anchor: NSView) {
        panel?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: CIStatusPanel(session: session) { [weak popover] in
            popover?.close()
        })
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
        panel = popover
    }
}

/// CIStatusPanel is the CI line's detail: the PR and its reviews, then every run, each opening its GitHub page.
/// It follows the session live and closes itself when the line goes.
struct CIStatusPanel: View {
    let session: Session
    let close: () -> Void

    var body: some View {
        Group {
            if let ci = session.effectiveCI { content(ci) }
        }
        .padding(12)
        .frame(minWidth: 240, alignment: .leading)
        .onChange(of: session.effectiveCI == nil) { _, gone in if gone { close() } }
    }

    private func content(_ ci: CIStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let pr = ci.pr {
                link("#\(pr.number) \(pr.title)", pr.url).font(.headline)
                reviews(pr)
            } else {
                Text("\(ci.branch) · \(String(ci.sha.prefix(7)))").font(.headline)
            }
            ForEach([CIRunState.failed, .running, .passed, .skipped], id: \.self) { state in
                let runs = ci.runs.filter { $0.state == state }
                if !runs.isEmpty {
                    Text(Self.title(state)).font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                        Button { open(run.url) } label: {
                            HStack(spacing: 6) {
                                Text(Self.glyph(state)).foregroundStyle(Self.color(state))
                                Text(run.workflow).foregroundStyle(state == .skipped ? .secondary : .primary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder private func reviews(_ pr: CIPullRequest) -> some View {
        if pr.approved.isEmpty, pr.changesRequested.isEmpty {
            Text("No reviews yet").foregroundStyle(.secondary)
        }
        if !pr.approved.isEmpty { Text("Approved: \(pr.approved.joined(separator: ", "))") }
        if !pr.changesRequested.isEmpty { Text("Changes requested: \(pr.changesRequested.joined(separator: ", "))") }
    }

    private func link(_ title: String, _ url: String) -> some View {
        Button(title) { open(url) }.buttonStyle(.link)
    }

    private func open(_ url: String) {
        guard let url = URL(string: url), url.scheme == "https" else { return }
        NSWorkspace.shared.open(url)
        close()
    }

    private static func title(_ state: CIRunState) -> String {
        switch state {
        case .failed: "Failed"
        case .running: "Running"
        case .passed: "Passed"
        case .skipped: "Skipped"
        }
    }

    private static func glyph(_ state: CIRunState) -> String {
        switch state {
        case .failed: "✗"
        case .running: "◷"
        case .passed: "✓"
        case .skipped: "–"
        }
    }

    private static func color(_ state: CIRunState) -> Color {
        switch state {
        case .failed: Color(nsColor: .tint(.red))
        case .running: Color(nsColor: .tint(.yellow))
        case .passed: Color(nsColor: .tint(.green))
        case .skipped: .secondary
        }
    }
}
