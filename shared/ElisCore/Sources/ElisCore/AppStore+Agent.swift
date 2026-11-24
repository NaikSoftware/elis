import Foundation

/// AgentPaneSample is what the app's sampler saw in one pane: the agent in its foreground group and, for Claude,
/// the first `sessions/<pid>.json` that parses; for Antigravity, the conversation it holds (`AntigravityHome`).
public struct AgentPaneSample: Sendable, Equatable {
    public var pane: StatusPane
    public var agent: SessionLauncher?
    public var claudeSessionJSON: Data?
    public var antigravityConversation: String?

    public init(pane: StatusPane, agent: SessionLauncher?, claudeSessionJSON: Data?, antigravityConversation: String? = nil) {
        self.pane = pane
        self.agent = agent
        self.claudeSessionJSON = claudeSessionJSON
        self.antigravityConversation = antigravityConversation
    }
}

extension AppStore {
    /// applyAgentSamples records the focused pane's agent, else the other pane's, and the Claude or agy id that pane reports.
    public func applyAgentSamples(_ samples: [AgentPaneSample], focused: StatusPane, forSession id: UUID) {
        guard let session = session(withID: id) else { return }
        let pick = samples.first { $0.pane == focused && $0.agent != nil } ?? samples.first { $0.agent != nil }
        setRunningAgent(pick?.agent, pane: pick?.pane, forSession: id)
        guard let pick, let agent = pick.agent else { return }
        // only a new value replaces the old, so a session closed after claude exits still resumes it;
        // another agent puts its own id (agy's conversation) or none, since Claude's no longer names what the session runs
        guard agent == .claude else { return setAgentSessionID(agent == .antigravity ? pick.antigravityConversation : nil, forSession: id) }
        guard let json = pick.claudeSessionJSON, let claudeID = SessionLauncher.claudeSessionID(json: json) else { return }
        if let line = SessionLauncher.claudeResumeLine(json: json) { session.resumeLine = line }
        setAgentSessionID(claudeID, forSession: id)
    }

    /// setRunningAgent records the session's agent and its pane, and tells viewers and the tree when either changed.
    public func setRunningAgent(_ agent: SessionLauncher?, pane: StatusPane?, forSession id: UUID) {
        guard let session = session(withID: id), session.runningAgent != agent || session.agentPane != pane else { return }
        if session.runningAgent != agent { session.runningAgent = agent }
        session.agentPane = pane
        presentationHub?.publish(.agent(presentationAgent(of: session)), session: id)
        scheduleTreeChanged()
    }

    /// applyRemoteAgent records the origin's running agent on an attached row; a name that is not an agent, or a pane
    /// other than left or right, reads as none.
    /// shortcut: the origin's pane role is taken as the local one, wrong only after a swap on one Mac.
    public func applyRemoteAgent(_ agent: PresentationAgent?, forSession id: UUID) {
        guard let session = session(withID: id), session.remotePresentation != nil else { return }
        let launcher = agent.flatMap { SessionLauncher(rawValue: $0.name) }.flatMap { $0 == .terminal ? nil : $0 }
        let pane = agent.flatMap { StatusPane(rawValue: $0.pane) }.flatMap { $0 == .scratch ? nil : $0 }
        let known = launcher != nil && pane != nil
        let (newAgent, newPane) = known ? (launcher, pane) : (nil, nil)
        guard session.runningAgent != newAgent || session.agentPane != newPane else { return }
        if session.runningAgent != newAgent { session.runningAgent = newAgent }
        session.agentPane = newPane
        scheduleTreeChanged()
    }

    func presentationAgent(of session: Session) -> PresentationAgent? {
        guard let agent = session.runningAgent, let pane = session.agentPane else { return nil }
        return PresentationAgent(name: agent.rawValue, pane: pane.rawValue)
    }
}

extension Session {
    /// transcriptSource names the Claude or agy transcript `pane` runs, the agent's pane by default; any other pane is refused.
    /// An agy pane before its first prompt has no conversation yet, so its empty id reads as `transcript not found`.
    public func transcriptSource(token: String?, pane: StatusPane?, claudeDirectory: String = ClaudeHome.directory(),
                                 antigravityDirectory: String = AntigravityHome.directory())
        -> Result<ControlTranscriptSource, ControlTranscriptRefusal> {
        let resolved: StatusPane
        switch paneAddress(token: token, pane: pane) {
        case .unknownToken(let token): return .failure(ControlTranscriptRefusal(message: "unknown pane id: \(token)"))
        case .pane(let addressed): resolved = addressed ?? agentPane ?? .left
        }
        guard let agent = runningAgent, [.claude, .antigravity].contains(agent),
              let id = agentSessionID ?? (agent == .antigravity ? "" : nil), resolved == agentPane
        else { return .failure(.noAdapter) }
        return .success(ControlTranscriptSource(claudeSessionID: id, pane: resolved,
                                                claudeDirectory: agent == .claude ? claudeDirectory : antigravityDirectory, agent: agent))
    }
}
