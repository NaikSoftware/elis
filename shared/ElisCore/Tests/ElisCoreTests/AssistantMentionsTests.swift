import ElisCore
import Testing

struct AssistantMentionsTests {
    private static let filter = "A8BA15A4-73FE-45D7-89A9-9D764EDF9389"
    private static let notes = "E0703062-9C0F-4346-9BC2-C1A2B143D12F"
    private static let gone = "11111111-2222-4333-8444-555555555555"
    private let directory = AssistantDirectory([
        AssistantPeer(sessionID: filter, window: "w", workspaceID: "ws", workspaceName: "elis", name: "sidebar-filter"),
        AssistantPeer(sessionID: notes, window: "w", workspaceID: "ws", workspaceName: "elis", name: "release-notes"),
    ])

    @Test func aReplyFrameBecomesItsSessionsMention() {
        let segments = AssistantMentions.segments("[reply from @side-filter \(Self.filter)] The chip is wired.", in: directory)
        #expect(segments == [.mention(sessionID: Self.filter, handle: "side-filter"), .text(" The chip is wired.")])
    }

    @Test func aFrameNamesTheSessionsCurrentHandleNotTheOneItCarries() {
        let segments = AssistantMentions.segments("[reply from @old-name \(Self.notes)] done", in: directory)
        #expect(segments == [.mention(sessionID: Self.notes, handle: "rele-notes"), .text(" done")])
    }

    @Test func aFrameOfAnEndedSessionKeepsItsIdOutOfTheText() {
        let segments = AssistantMentions.segments("[reply from @zsh \(Self.gone)] bye", in: directory)
        #expect(segments == [.mention(sessionID: Self.gone, handle: nil), .text(" bye")])
    }

    @Test func aBareKnownIdBecomesAMentionAndAnUnknownOneStaysText() {
        let lower = Self.filter.lowercased()
        let segments = AssistantMentions.segments("ask \(lower), not \(Self.gone).", in: directory)
        #expect(segments == [.text("ask "), .mention(sessionID: Self.filter, handle: "side-filter"), .text(", not \(Self.gone).")])
    }

    @Test func aKnownIdInsideABareURLStaysText() {
        let text = "see https://example.com/s/\(Self.filter.lowercased()) now"
        #expect(AssistantMentions.segments(text, in: directory) == [.text(text)])
    }

    @Test func textWithoutIdsIsOneSegment() {
        #expect(AssistantMentions.segments("**Status**\n- all green", in: directory) == [.text("**Status**\n- all green")])
        #expect(AssistantMentions.segments("", in: directory) == [])
    }
}
