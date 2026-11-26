import Foundation
import Testing
@testable import ElisCore

private final class SplitSurface: TerminalSurface {
    var paneToken = ""
    var isRealized = true
    func teardown() {}
    func promoteToPrimaryPane() {}
}

@MainActor
struct AppStorePaneAgentCwdTests {
    private func splitSession() throws -> (AppStore, Session) {
        let store = makeStore()
        let session = try #require(store.addSession(toWorkspace: store.addWorkspace(name: "work").id, cwd: "/repo"))
        store.toggleSplit(session.id)
        return (store, session)
    }

    private func report(_ store: AppStore, _ session: Session, _ status: AgentStatus, pane: StatusPane, cwd: String?,
                        ifIdle: Bool = false) {
        store.applyControlStatus(AgentIndicator(status: status, statusPane: pane), forSession: session.id, ifIdle: ifIdle, cwd: cwd)
    }

    @Test func aStatusRecordsItsPanesAgentCwd() throws {
        let (store, session) = try splitSession()
        report(store, session, .active, pane: .right, cwd: "/repo/.claude/worktrees/a")
        #expect(session.paneAgentCwd == [.right: "/repo/.claude/worktrees/a"])
    }

    @Test func aWriteUnderAnotherPanesBlockStillRecordsTheCwd() throws {
        let (store, session) = try splitSession()
        report(store, session, .blocked, pane: .left, cwd: nil)
        report(store, session, .active, pane: .right, cwd: "/wt")
        #expect(session.agentIndicator.status == .blocked)
        #expect(session.paneAgentCwd[.right] == "/wt")
    }

    @Test func aSkippedIfIdleWriteDropsItsCwd() throws {
        let (store, session) = try splitSession()
        report(store, session, .active, pane: .left, cwd: nil)
        report(store, session, .active, pane: .right, cwd: "/wt", ifIdle: true)
        #expect(session.paneAgentCwd.isEmpty)
    }

    @Test(arguments: [nil, ""])
    func aWriteWithoutACwdKeepsTheLastOne(_ cwd: String?) throws {
        let (store, session) = try splitSession()
        report(store, session, .active, pane: .left, cwd: "/wt")
        report(store, session, .completed, pane: .left, cwd: cwd)
        #expect(session.paneAgentCwd[.left] == "/wt")
    }

    @Test func theScratchCwdIsIgnored() throws {
        let (store, session) = try splitSession()
        report(store, session, .active, pane: .scratch, cwd: "/wt")
        #expect(session.paneAgentCwd.isEmpty)
    }

    @Test func clearingTheStatusKeepsTheCwd() throws {
        let (store, session) = try splitSession()
        report(store, session, .active, pane: .left, cwd: "/wt")
        store.clearStatus(session.id)
        store.clearStatus(by: .interrupt, pane: .left, reset: .firstKey, forSession: session.id)
        #expect(session.paneAgentCwd[.left] == "/wt")
    }

    @Test func aSampleWithoutAnAgentClearsOnlyThatPane() throws {
        let (store, session) = try splitSession()
        report(store, session, .active, pane: .left, cwd: "/a")
        report(store, session, .active, pane: .right, cwd: "/b")
        store.applyAgentSamples([AgentPaneSample(pane: .left, agent: nil, claudeSessionJSON: nil),
                                 AgentPaneSample(pane: .right, agent: .claude, claudeSessionJSON: nil)],
                                focused: .left, forSession: session.id)
        #expect(session.paneAgentCwd == [.right: "/b"])
        store.applyAgentSamples([AgentPaneSample(pane: .right, agent: nil, claudeSessionJSON: nil)],
                                focused: .left, forSession: session.id)
        #expect(session.paneAgentCwd.isEmpty)
    }

    @Test func aSwapCarriesEachPanesCwd() throws {
        let (store, session) = try splitSession()
        report(store, session, .active, pane: .left, cwd: "/a")
        #expect(store.swapPanes(session.id, allowingUnrealized: true) == nil)
        #expect(session.paneAgentCwd == [.right: "/a"])
    }

    @Test func promotionMovesTheSurvivorsCwdLeft() throws {
        let (store, session) = try splitSession()
        report(store, session, .active, pane: .left, cwd: "/a")
        report(store, session, .active, pane: .right, cwd: "/b")
        store.promoteSplit(session)
        #expect(session.paneAgentCwd == [.left: "/b"])
    }

    @Test func closingTheSplitDropsItsCwd() throws {
        let (store, session) = try splitSession()
        report(store, session, .active, pane: .left, cwd: "/a")
        report(store, session, .active, pane: .right, cwd: "/b")
        store.closeSplit(session.id)
        #expect(session.paneAgentCwd == [.left: "/a"])
    }

    @Test func respawningThePrimaryDropsEveryCwd() throws {
        let (store, session) = try splitSession()
        report(store, session, .active, pane: .left, cwd: "/a")
        store.respawnPrimaryPane(session, now: Date())
        #expect(session.paneAgentCwd.isEmpty)
    }

    @Test func ciCwdIsTheFocusedPanesAgentCwdElseItsShellCwd() throws {
        let (store, session) = try splitSession()
        session.currentCwd = "/repo"
        #expect(session.ciCwd == "/repo")
        report(store, session, .active, pane: .left, cwd: "/wt")
        #expect(session.ciCwd == "/wt")
    }

    @Test func aFocusedSplitReadsOnlyItsOwnAgentCwd() throws {
        let (store, session) = try splitSession()
        session.splitSurface = SplitSurface()
        session.splitFocused = true
        session.splitCwd = "/repo/sub"
        report(store, session, .active, pane: .left, cwd: "/a")
        #expect(session.ciCwd == "/repo/sub")
        report(store, session, .active, pane: .right, cwd: "/b")
        #expect(session.ciCwd == "/b")
    }
}
