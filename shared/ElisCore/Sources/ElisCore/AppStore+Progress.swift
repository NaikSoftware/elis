import Foundation

/// The terminal's progress and the pane that reported it; `token` tells a stale expiry from the latest update.
public struct TerminalProgressSlot: Sendable, Equatable {
    public let progress: SessionProgress
    public let pane: StatusPane?
    public let token: UUID
}

extension Session {
    /// shownProgress is what the row fills: the control API's progress, else the terminal's.
    public var shownProgress: (progress: SessionProgress, source: ProgressSource)? {
        if let controlProgress { return (controlProgress, .control) }
        return terminalProgress.map { ($0.progress, .terminal) }
    }
}

extension AppStore {
    /// setControlProgress sets or (nil) clears `session progress`; a status change into completed or idle also clears it.
    public func setControlProgress(_ progress: SessionProgress?, forSession id: UUID) {
        guard let session = session(withID: id) else { return }
        changeProgress(of: session) { $0.controlProgress = progress }
    }

    /// setTerminalProgress applies OSC 9;4 from `pane`. A clear from another pane is ignored, and a set expires
    /// `terminalProgressTimeout` after the pane's last update, since a killed program never sends its clear.
    public func setTerminalProgress(_ update: TerminalProgressUpdate, forSession id: UUID, pane: StatusPane?) {
        guard let session = session(withID: id) else { return }
        switch update {
        case .clear:
            clearTerminalProgress(of: session, pane: pane ?? .left)
        case .set(let progress):
            let token = UUID()
            changeProgress(of: session) { $0.terminalProgress = TerminalProgressSlot(progress: progress, pane: pane, token: token) }
            let timeout = terminalProgressTimeout
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self, let session = self.session(withID: id), session.terminalProgress?.token == token else { return }
                self.changeProgress(of: session) { $0.terminalProgress = nil }
            }
        }
    }

    func clearTerminalProgress(of session: Session, pane: StatusPane) {
        guard let slot = session.terminalProgress, (slot.pane ?? .left) == pane else { return }
        changeProgress(of: session) { $0.terminalProgress = nil }
    }

    /// moveTerminalProgress re-tags the slot when panes swap or promote; a nil result means its pane is gone.
    func moveTerminalProgress(of session: Session, _ move: (StatusPane) -> StatusPane?) {
        guard let slot = session.terminalProgress else { return }
        let pane = slot.pane ?? .left
        guard let moved = move(pane) else { return clearTerminalProgress(of: session, pane: pane) }
        session.terminalProgress = TerminalProgressSlot(progress: slot.progress, pane: moved, token: slot.token)
    }

    func progressNode(of session: Session) -> ControlProgressNode? {
        session.shownProgress.map {
            ControlProgressNode(value: $0.progress.label, fraction: $0.progress.fraction, source: $0.source.rawValue)
        }
    }

    /// changeProgress emits `progress` only when what the row shows changes.
    func changeProgress(of session: Session, _ change: (Session) -> Void) {
        let before = session.shownProgress
        change(session)
        let after = session.shownProgress
        guard before?.progress != after?.progress || before?.source != after?.source else { return }
        emitControlEvent(.progress, workspace: workspace(forSession: session.id)?.id, session: session.id,
                         payload: ControlEventPayload(name: session.displayName, progress: after?.progress.label,
                                                      source: after?.source.rawValue))
    }
}
