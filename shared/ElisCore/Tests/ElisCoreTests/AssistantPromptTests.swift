import Foundation
import Testing
@testable import ElisCore

@Suite struct AssistantPromptTests {
    @Test func promptListsEveryPeerAndTheRules() {
        let directory = AssistantDirectory([
            AssistantPeer(sessionID: "claude1", window: "w1", workspaceID: "wsE", workspaceName: "elis", name: "claude 1", agent: "claude", status: "idle"),
            AssistantPeer(sessionID: "shell1", window: "w1", workspaceID: "wsE", workspaceName: "elis", name: "zsh"),
        ])
        let prompt = AssistantPrompt.system(directory)
        #expect(prompt.contains("elisctl assistant send"))
        #expect(prompt.contains("[reply from @<handle> <session id>] <text>"))
        #expect(prompt.contains("snapshot") && prompt.contains("elisctl tree --json"))
        #expect(prompt.contains("@ws:"))
        #expect(prompt.contains("@all"))
        for peer in directory.peers {
            let handle = directory.handle(of: peer.sessionID) ?? ""
            let row = "\(handle) | \(peer.workspaceName) | \(peer.agent ?? "-") | \(peer.status ?? "-") | \(peer.sessionID)"
            #expect(prompt.contains(row))
        }
    }

    @Test func inlineRecapsOneEntryPerLine() {
        let entries = [
            AssistantEntry(id: UUID(), kind: .user, from: nil, to: nil, text: "ask\n@zsh", ts: 1),
            AssistantEntry(id: UUID(), kind: .sent, from: nil, to: ["shell1"], text: "run it", ts: 2),
            AssistantEntry(id: UUID(), kind: .reply, from: "shell1", to: nil, text: "done", ts: 3),
        ]
        #expect(AssistantPrompt.inline(entries) == """
        Earlier messages in this chat, oldest first:
        user: ask @zsh
        sent: run it
        reply @shell1: done
        """)
        #expect(AssistantPrompt.inline([]) == "")
    }
}
