import Foundation
import Testing
@testable import ElisCore

@MainActor @Suite struct AssistantChatTests {
    func tempFile() -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (dir, dir.appendingPathComponent("chat.jsonl"))
    }

    @Test func userMessageClearsMarks() {
        let chat = AssistantChat()
        chat.append(.sent, text: "go", to: ["a", "b"], now: 1)
        chat.markSkipped(["c"])
        #expect(chat.marks == ["a": .waiting, "b": .waiting, "c": .notDelivered])
        chat.append(.user, text: "next", now: 2)
        #expect(chat.marks.isEmpty)
    }

    @Test func replyMarksSenderAndCountsUnread() {
        let chat = AssistantChat()
        chat.append(.sent, text: "go", to: ["a"], now: 1)
        chat.append(.reply, text: "done", from: "a", now: 2)
        #expect(chat.marks["a"] == .replied)
        #expect(chat.unread == 1)
    }

    @Test func markSeenZeroesUnread() {
        let chat = AssistantChat()
        chat.append(.reply, text: "x", from: "a", now: 1)
        chat.markSeen()
        #expect(chat.unread == 0)
    }

    @Test func runningLastsUntilEveryQueuedInputEnds() {
        let chat = AssistantChat()
        chat.inputQueued()
        chat.inputQueued()
        chat.turnEnded()
        #expect(chat.running)
        chat.turnEnded()
        #expect(!chat.running)
    }

    @Test func turnEndedNeverGoesBelowZero() {
        let chat = AssistantChat()
        chat.turnEnded()
        chat.inputQueued()
        #expect(chat.running)
    }

    @Test func turnFailureRecordsTheErrorAndEndsOnlyThatTurn() {
        let chat = AssistantChat()
        chat.inputQueued()
        chat.inputQueued()
        let entry = chat.turnFailed("rate limited", now: 5)
        #expect([entry.kind.rawValue, entry.text] == ["error", "rate limited"])
        #expect(chat.entries(last: 1) == [entry])
        #expect(chat.running)
        chat.turnEnded()
        #expect(!chat.running)
    }

    @Test func settledEntriesLeaveOutTheQueuedInputs() {
        let chat = AssistantChat()
        chat.append(.user, text: "answered", now: 1)
        chat.append(.assistant, text: "yes", now: 2)
        chat.append(.user, text: "queued", now: 3)
        chat.inputQueued()
        chat.append(.sent, text: "go", to: ["a"], now: 4)
        chat.append(.reply, text: "done", from: "a", now: 5)
        chat.inputQueued()
        #expect(chat.settledEntries(last: 50).map(\.text) == ["answered", "yes", "go"])
        #expect(chat.settledEntries(last: 1).map(\.text) == ["go"])
    }

    @Test func providerFailureRecordsTheErrorAndClearsTheQueue() {
        let chat = AssistantChat()
        chat.inputQueued()
        chat.inputQueued()
        chat.providerFailed("claude not found", now: 5)
        #expect(!chat.running)
        #expect(chat.entries(last: 1).map { [$0.kind.rawValue, $0.text] } == [["error", "claude not found"]])
    }

    @Test func reloadRestoresEntriesAndProvider() {
        let (dir, file) = tempFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        let chat = AssistantChat(file: file)
        chat.provider = .codex
        chat.append(.user, text: "hi", now: 1)
        chat.append(.assistant, text: "hello", now: 2)
        let again = AssistantChat(file: file)
        #expect(again.entries(last: nil) == chat.entries(last: nil))
        #expect(again.entries(last: nil).count == 2)
        #expect(again.provider == .codex)
    }

    @Test func clearEmptiesTheChatAndForgetsConversationsButKeepsTheProvider() {
        let (dir, file) = tempFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        let chat = AssistantChat(file: file)
        chat.provider = .codex
        chat.resume[.codex] = "x-1"
        chat.append(.sent, text: "go", to: ["s1"], now: 1)
        chat.append(.reply, text: "done", from: "s1", now: 2)
        chat.inputQueued()
        chat.clear()
        #expect(chat.entries(last: nil).isEmpty && chat.marks.isEmpty && chat.unread == 0 && !chat.running && chat.resume.isEmpty)
        let reopened = AssistantChat(file: file)
        #expect(reopened.entries(last: nil).isEmpty && reopened.resume.isEmpty && reopened.provider == .codex)
        let after = chat.append(.user, text: "again", now: 3)
        #expect(AssistantChat(file: file).entries(last: nil) == [after])
    }

    @Test func resumeIDsPersistPerProvider() throws {
        let (dir, file) = tempFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        let chat = AssistantChat(file: file)
        chat.resume[.claude] = "c-1"
        chat.resume[.codex] = "x-1"
        chat.resume[.claude] = "c-2"
        #expect(AssistantChat(file: file).resume == [.claude: "c-2", .codex: "x-1"])

        try Data(#"{"claude":"c-3","nope":"z"}"#.utf8).write(to: file.appendingPathExtension("resume"))
        #expect(AssistantChat(file: file).resume == [.claude: "c-3"])
        try Data("not json".utf8).write(to: file.appendingPathExtension("resume"))
        #expect(AssistantChat(file: file).resume.isEmpty)
    }

    @Test func transcriptKeepsTheLast500() {
        let (dir, file) = tempFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        let chat = AssistantChat(file: file)
        for i in 1...650 { chat.append(.user, text: "m\(i)", now: Double(i)) }
        #expect(chat.entries(last: nil).count == 500)
        let again = AssistantChat(file: file).entries(last: nil)
        #expect(again.count == 500)
        #expect(again.first?.text == "m151")
        #expect(again.last?.text == "m650")
        #expect(chat.entries(last: 2).map(\.text) == ["m649", "m650"])
    }

    @Test func appendAfterATornLineStartsOnItsOwnLine() throws {
        let (dir, file) = tempFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        AssistantChat(file: file).append(.user, text: "a", now: 1)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"id":"#.utf8))
        try handle.close()
        AssistantChat(file: file).append(.user, text: "b", now: 2)
        #expect(AssistantChat(file: file).entries(last: nil).map(\.text) == ["a", "b"])
    }

    @Test func undecodableLineIsSkipped() throws {
        let (dir, file) = tempFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        let chat = AssistantChat(file: file)
        chat.append(.user, text: "a", now: 1)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n".utf8))
        try handle.close()
        chat.append(.user, text: "b", now: 2)
        #expect(AssistantChat(file: file).entries(last: nil).map(\.text) == ["a", "b"])
    }
}
