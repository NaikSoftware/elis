import Testing
@testable import ElisCore

struct SidebarBandTests {
    @Test func edgeFollowsThePositionInTheGroup() {
        #expect(SidebarBand.edge(index: 0, count: 1) == .single)
        #expect((0..<3).map { SidebarBand.edge(index: $0, count: 3) } == [.first, .middle, .last])
        #expect((0..<2).map { SidebarBand.edge(index: $0, count: 2) } == [.first, .last])
    }

    @Test func edgeClampsAnOutOfRangeIndex() {
        #expect(SidebarBand.edge(index: -1, count: 3) == .first)
        #expect(SidebarBand.edge(index: 5, count: 3) == .last)
        #expect(SidebarBand.edge(index: 4, count: 0) == .single)
    }

    @Test(arguments: [AgentStatus.idle, .blocked, .completed])
    func waveOnlyForActive(status: AgentStatus) {
        #expect(SidebarBand.wave(status: status, sessionTintHex: "#111111", workspaceTintHex: nil,
                                 activeHex: "#AAAAAA", accentHex: "#BBBBBB") == nil)
    }

    @Test func waveBasePrefersSessionThenWorkspaceThenActive() {
        let both = SidebarBand.wave(status: .active, sessionTintHex: "#111111", workspaceTintHex: "#222222",
                                    activeHex: "#AAAAAA", accentHex: "#BBBBBB")
        #expect(both == SidebarWave(base: "#111111", second: "#AAAAAA"))
        let workspace = SidebarBand.wave(status: .active, sessionTintHex: nil, workspaceTintHex: "#222222",
                                         activeHex: "#AAAAAA", accentHex: "#BBBBBB")
        #expect(workspace == SidebarWave(base: "#222222", second: "#AAAAAA"))
        let plain = SidebarBand.wave(status: .active, sessionTintHex: nil, workspaceTintHex: nil,
                                     activeHex: "#AAAAAA", accentHex: "#BBBBBB")
        #expect(plain == SidebarWave(base: "#AAAAAA", second: "#BBBBBB"))
    }

    @Test func fillUsesSessionThenWorkspaceThenActive() {
        func fill(_ session: String?, _ workspace: String?) -> SidebarProgressFill? {
            SidebarBand.progressFill(progress: .steps(done: 3, total: 7), status: .active, sessionTintHex: session,
                                     workspaceTintHex: workspace, activeHex: "#3ccf64")
        }
        #expect(fill("#a970ff", "#ff9f43") == SidebarProgressFill(colorHex: "#a970ff", fraction: 3.0 / 7))
        #expect(fill(nil, "#ff9f43")?.colorHex == "#ff9f43")
        #expect(fill(nil, nil)?.colorHex == "#3ccf64")
    }

    @Test func blockedAndIndeterminateDrawNoFill() {
        #expect(SidebarBand.progressFill(progress: .percent(40), status: .blocked, sessionTintHex: nil,
                                         workspaceTintHex: nil, activeHex: "#3ccf64") == nil)
        #expect(SidebarBand.progressFill(progress: .indeterminate, status: .active, sessionTintHex: nil,
                                         workspaceTintHex: nil, activeHex: "#3ccf64") == nil)
        #expect(SidebarBand.progressFill(progress: nil, status: .active, sessionTintHex: nil,
                                         workspaceTintHex: nil, activeHex: "#3ccf64") == nil)
    }

    @Test func fillFractionClampsToOne() {
        #expect(SidebarBand.progressFill(progress: .percent(100), status: .idle, sessionTintHex: nil,
                                         workspaceTintHex: nil, activeHex: "#3ccf64")?.fraction == 1.0)
        #expect(SidebarBand.progressFill(progress: .percent(250), status: .idle, sessionTintHex: nil,
                                         workspaceTintHex: nil, activeHex: "#3ccf64")?.fraction == 1.0)
    }

    @Test func indeterminateShowsTheWaveWithoutAgentStatus() {
        #expect(SidebarBand.wave(status: .idle, indeterminate: true, sessionTintHex: nil, workspaceTintHex: nil,
                                 activeHex: "#3ccf64", accentHex: "#6b9bff") == SidebarWave(base: "#3ccf64", second: "#6b9bff"))
        #expect(SidebarBand.wave(status: .blocked, indeterminate: true, sessionTintHex: nil, workspaceTintHex: nil,
                                 activeHex: "#3ccf64", accentHex: "#6b9bff") == nil)
        #expect(SidebarBand.wave(status: .idle, indeterminate: false, sessionTintHex: nil, workspaceTintHex: nil,
                                 activeHex: "#3ccf64", accentHex: "#6b9bff") == nil)
    }
}
