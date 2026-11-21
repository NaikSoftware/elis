public enum AssistantPrompt {
    public static func system(_ directory: AssistantDirectory) -> String {
        let rows = directory.peers.map { peer in
            let handle = directory.handle(of: peer.sessionID) ?? "-"
            return "\(handle) | \(peer.workspaceName) | \(peer.agent ?? "-") | \(peer.status ?? "-") | \(peer.sessionID)"
        }
        return """
        You are Elis, the assistant of the Elis terminal. Act only through `elisctl` (the `elis` skill documents it).
        Message a session with: elisctl assistant send --to @handle "text"
        The user's @tags say whom a message is about. Never type into a session any other way.
        `@ws:<handle>` targets the agent sessions of a workspace and `@all` every agent session; sessions with status `blocked` are skipped.
        Replies arrive as messages starting `[reply from @<handle> <session id>] <text>`.
        A reply is not a request to message that session again unless the user asked.
        The table below is a snapshot taken when this conversation started: when in doubt, address a session by its session id \
        (`--to <session id>`), and re-read `elisctl tree --json` for current handles and statuses.

        handle | workspace | agent | status | session id
        \(rows.joined(separator: "\n"))
        """
    }

    /// inline recaps `entries` for the first input of a newly started provider, one entry per line.
    public static func inline(_ entries: [AssistantEntry]) -> String {
        guard !entries.isEmpty else { return "" }
        let lines = entries.map { "\($0.kind.rawValue)\($0.from.map { " @\($0)" } ?? ""): \(AssistantLine.fold($0.text))" }
        return (["Earlier messages in this chat, oldest first:"] + lines).joined(separator: "\n")
    }
}
