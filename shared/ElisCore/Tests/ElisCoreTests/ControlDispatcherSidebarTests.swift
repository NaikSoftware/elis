import Foundation
import Testing
@testable import ElisCore

@MainActor
struct ControlDispatcherSidebarTests {
    @Test(arguments: [("flat", .flat), ("plain", .plain), ("tree", .tree), ("toggle", .toggle), (nil, .toggle)] as [(String?, ControlFlaggedLayoutMode)])
    func flaggedLayoutRoutesTheParsedMode(_ raw: String?, _ mode: ControlFlaggedLayoutMode) async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextFlaggedViewLayoutResponse = ControlResponse(ok: true, result: ControlResult(text: "tree"))

        let response = await dispatcher.dispatch(
            ControlRequest(cmd: .sidebarFlaggedLayout, args: ControlArgs(mode: raw)))

        #expect(response == ControlResponse(ok: true, result: ControlResult(text: "tree")))
        #expect(actions.calls == [.flaggedViewLayout(mode)])
    }

    @Test func flaggedLayoutRejectsAnUnknownModeWithoutCallingActions() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(
            ControlRequest(cmd: .sidebarFlaggedLayout, args: ControlArgs(mode: "grid")))

        #expect(response == ControlResponse(ok: false, error: "invalid flagged layout: grid"))
        #expect(actions.calls.isEmpty)
    }

    @Test(arguments: [("default", .standard), ("compact", .compact), ("toggle", .toggle), (nil, .toggle)] as [(String?, ControlSidebarDensityMode)])
    func sidebarDensityRoutesTheParsedMode(_ raw: String?, _ mode: ControlSidebarDensityMode) async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextSidebarDensityResponse = ControlResponse(ok: true, result: ControlResult(text: "compact"))

        let response = await dispatcher.dispatch(ControlRequest(cmd: .sidebarDensity, args: ControlArgs(mode: raw)))

        #expect(response == ControlResponse(ok: true, result: ControlResult(text: "compact")))
        #expect(actions.calls == [.sidebarDensity(mode)])
    }

    @Test func sidebarDensityRejectsAnUnknownModeWithoutCallingActions() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(cmd: .sidebarDensity, args: ControlArgs(mode: "dense")))

        #expect(response == ControlResponse(ok: false, error: "invalid sidebar density: dense"))
        #expect(actions.calls.isEmpty)
    }

    @Test(arguments: [("on", .on), ("off", .off), ("toggle", .toggle), (nil, .toggle)] as [(String?, ControlToggleMode)])
    func keepAwakeRoutesTheParsedMode(_ raw: String?, _ mode: ControlToggleMode) async {
        let actions = MockControlActions()
        actions.nextKeepAwakeResponse = ControlResponse(ok: true, result: ControlResult(text: "off"))

        let response = await ControlDispatcher(actions: actions).dispatch(ControlRequest(cmd: .settingsKeepAwake, args: ControlArgs(mode: raw)))

        #expect(response == ControlResponse(ok: true, result: ControlResult(text: "off")))
        #expect(actions.calls == [.keepAwake(mode)])
    }

    @Test func keepAwakeRejectsAnUnknownModeWithoutCallingActions() async {
        let actions = MockControlActions()

        let response = await ControlDispatcher(actions: actions).dispatch(ControlRequest(cmd: .settingsKeepAwake, args: ControlArgs(mode: "always")))

        #expect(response == ControlResponse(ok: false, error: "invalid keep-awake mode: always"))
        #expect(actions.calls.isEmpty)
    }

    @Test func sidebarWidthRoutesPointsAndWindow() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextSidebarWidthResponse = ControlResponse(ok: true, result: ControlResult(sidebarWidth: 271.3))

        let response = await dispatcher.dispatch(
            ControlRequest(cmd: .sidebarWidth, args: ControlArgs(window: "win", sidebarWidth: 271.3)))

        #expect(response == ControlResponse(ok: true, result: ControlResult(sidebarWidth: 271.3)))
        #expect(actions.calls == [.sidebarWidth(points: 271.3, window: "win")])
    }

    @Test func sidebarWidthDefaultsToFrontmostWindow() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(cmd: .sidebarWidth, args: ControlArgs(sidebarWidth: 300)))

        #expect(actions.calls == [.sidebarWidth(points: 300, window: nil)])
    }

    @Test(arguments: [nil, Double.nan, Double.infinity])
    func sidebarWidthRejectsMissingOrNonFinitePointsWithoutCallingActions(_ points: Double?) async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(
            ControlRequest(cmd: .sidebarWidth, args: ControlArgs(sidebarWidth: points)))

        #expect(response == ControlResponse(ok: false, error: "sidebar.width requires a width in points"))
        #expect(actions.calls.isEmpty)
    }
}
