import Foundation
import Testing
@testable import ElisCore

@MainActor
private final class ProgressDrafts {
    var payloads: [ControlEventPayload] = []
}

@MainActor
struct AppStoreProgressTests {
    private let drafts = ProgressDrafts()
    private let store: AppStore
    private let session: Session

    init() throws {
        let drafts = drafts
        store = AppStore(persistence: PersistenceStore(directory: FileManager.default.temporaryDirectory
                             .appendingPathComponent("elis-tests-\(UUID().uuidString)")),
                         controlEventSink: { if $0.kind == .progress { drafts.payloads.append($0.payload) } })
        let ws = store.addWorkspace(name: "work")
        session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
    }

    private var shown: SessionProgress? { session.shownProgress?.progress }
    private var source: ProgressSource? { session.shownProgress?.source }

    private func status(_ status: AgentStatus) {
        store.setAgentIndicator(AgentIndicator(status: status), forSession: session.id)
    }

    private func terminal(_ update: TerminalProgressUpdate, pane: StatusPane? = .left) {
        store.setTerminalProgress(update, forSession: session.id, pane: pane)
    }

    @Test func controlProgressShowsAndEmitsOneEvent() {
        store.setControlProgress(.steps(done: 3, total: 7), forSession: session.id)
        store.setControlProgress(.steps(done: 3, total: 7), forSession: session.id)

        #expect(shown == .steps(done: 3, total: 7))
        #expect(source == .control)
        #expect(drafts.payloads.map(\.progress) == ["3/7"])
        #expect(drafts.payloads.map(\.source) == ["control"])
    }

    @Test func controlWinsOverTerminal() {
        terminal(.set(.percent(40)))
        store.setControlProgress(.steps(done: 1, total: 2), forSession: session.id)
        #expect(shown == .steps(done: 1, total: 2))
        #expect(source == .control)

        store.setControlProgress(nil, forSession: session.id)

        #expect(shown == .percent(40))
        #expect(source == .terminal)
    }

    @Test func completedEdgeClearsControlOnly() {
        status(.active)
        store.setControlProgress(.steps(done: 3, total: 7), forSession: session.id)
        terminal(.set(.percent(40)))

        status(.completed)

        #expect(session.controlProgress == nil)
        #expect(session.terminalProgress?.progress == .percent(40))
    }

    @Test func idleEdgeClearsControl() {
        status(.active)
        store.setControlProgress(.steps(done: 3, total: 7), forSession: session.id)
        status(.idle)
        #expect(session.controlProgress == nil)

        store.setControlProgress(.steps(done: 1, total: 7), forSession: session.id)
        status(.idle)

        #expect(session.controlProgress == .steps(done: 1, total: 7))
    }

    @Test func activeRewriteOfStopKeepsControl() {
        status(.active)
        store.setControlProgress(.steps(done: 3, total: 7), forSession: session.id)

        store.setAgentIndicator(AgentIndicator(status: .active, blink: true), forSession: session.id)

        #expect(session.controlProgress == .steps(done: 3, total: 7))
    }

    @Test func blockedKeepsControlForAfterTheBlock() {
        status(.active)
        store.setControlProgress(.steps(done: 3, total: 7), forSession: session.id)

        status(.blocked)
        status(.active)

        #expect(session.controlProgress == .steps(done: 3, total: 7))
    }

    @Test func terminalClearFromTheOtherPaneIsIgnored() {
        terminal(.set(.percent(40)), pane: .left)

        terminal(.clear, pane: .right)
        #expect(shown == .percent(40))

        terminal(.clear, pane: .left)
        #expect(session.shownProgress == nil)
    }

    @Test func closingThePaneClearsItsTerminalProgress() {
        terminal(.set(.percent(40)), pane: .right)
        store.clearPaneStatus(.left, of: session)
        #expect(shown == .percent(40))

        store.clearPaneStatus(.right, of: session)

        #expect(session.terminalProgress == nil)
    }

    @Test func closingThePrimaryPaneClearsItsProgressAndPromotesTheSplits() {
        let (store, session) = makeHeadlessSession(split: true)
        store.setTerminalProgress(.set(.percent(40)), forSession: session.id, pane: .left)
        #expect(store.closePrimaryPane(session.id) == .promoted)
        #expect(session.terminalProgress == nil)

        let (other, promoted) = makeHeadlessSession(split: true)
        other.setTerminalProgress(.set(.percent(40)), forSession: promoted.id, pane: .right)
        #expect(other.closePrimaryPane(promoted.id) == .promoted)
        #expect(promoted.terminalProgress?.pane == .left)
        other.setTerminalProgress(.clear, forSession: promoted.id, pane: .left)
        #expect(promoted.terminalProgress == nil)
    }

    @Test func swappingPanesMovesTerminalProgressWithItsPane() {
        let (store, session) = makeHeadlessSession(split: true)
        store.setTerminalProgress(.set(.percent(40)), forSession: session.id, pane: .left)

        #expect(store.swapPanes(session.id, allowingUnrealized: true) == nil)

        #expect(session.terminalProgress?.pane == .right)
        store.setTerminalProgress(.clear, forSession: session.id, pane: .left)
        #expect(session.terminalProgress != nil)
    }

    @Test func terminalProgressExpiresWithoutUpdates() async throws {
        store.terminalProgressTimeout = .milliseconds(50)
        terminal(.set(.percent(40)))

        let deadline = ContinuousClock.now + .seconds(10)
        while session.terminalProgress != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(session.terminalProgress == nil)
        #expect(drafts.payloads.map(\.progress) == ["40%", nil])
    }

    @Test func aTerminalUpdateRearmsTheExpiry() async throws {
        store.terminalProgressTimeout = .seconds(2)
        terminal(.set(.percent(40)))
        try await Task.sleep(for: .seconds(1))
        terminal(.set(.percent(50)))

        try await Task.sleep(for: .seconds(1.2))

        #expect(shown == .percent(50))
    }

    @Test func claudesOwnOSCClearKeepsPlanProgress() {
        store.setControlProgress(.steps(done: 3, total: 7), forSession: session.id)

        terminal(.set(.indeterminate))
        terminal(.clear)

        #expect(shown == .steps(done: 3, total: 7))
        #expect(source == .control)
        #expect(drafts.payloads.count == 1)
    }
}
