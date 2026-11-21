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
        Replies arrive as messages starting `[reply from @<handle>] <text>`.
        A reply is not a request to message that session again unless the user asked.

        handle | workspace | agent | status | session id
        \(rows.joined(separator: "\n"))
        """
    }
}
