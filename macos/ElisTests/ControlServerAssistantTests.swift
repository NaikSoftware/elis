import ElisCore
import XCTest
@testable import Elis

@MainActor
final class ControlServerAssistantTests: XCTestCase {
    private static let fake = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("linux/tests/fixtures/fake-provider.sh").path
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var actions: AppActions!
    private var server: ControlServer!

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory.appendingPathComponent("elis-assistant-host-\(UUID().uuidString)", isDirectory: true)
        library = WindowLibrary(directory: stateDir)
        actions = AppActions(library: library)
        actions.assistant = AssistantModel(stateDirectory: stateDir, standIn: ["/bin/bash", Self.fake])
        server = ControlServer(
            library: library, actions: actions,
            settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
            identity: AppIdentity(version: "9.9.9", commit: "testsha"),
            socketPath: stateDir.appendingPathComponent("control.sock").path)
        server.installAssistant()
    }

    override func tearDown() async throws {
        actions.assistant.runner.stopForQuit()
        server = nil
        actions = nil
        library = nil
        try? FileManager.default.removeItem(at: stateDir)
        try await super.tearDown()
    }

    private func run(_ cmd: Command, target: String? = nil, _ fill: (inout ControlArgs) -> Void = { _ in }) async -> ControlResponse {
        var args = ControlArgs()
        fill(&args)
        return await server.dispatch(ControlRequest(cmd: cmd, target: target, args: args))
    }

    private func tree() async throws -> ControlTree {
        let response = await run(.tree)
        return try XCTUnwrap(response.result?.tree)
    }

    private func entries() async -> [AssistantEntry] {
        await run(.assistantRead).result?.assistant?.entries ?? []
    }

    private func store() throws -> AppStore { try XCTUnwrap(library.activeStore) }

    private func session(remote: String? = nil) throws -> Session {
        let store = try store()
        return try XCTUnwrap(store.addSession(toWorkspace: try XCTUnwrap(store.currentWorkspaceID), cwd: "/tmp", remoteHost: remote))
    }

    private func waitFor(_ what: String, seconds: TimeInterval = 30, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "timed out waiting for \(what)")
    }

    private func anchor() async throws -> ControlEventBatch {
        let response = await run(.eventsRead)
        return try XCTUnwrap(response.result?.events)
    }

    private func events(after batch: ControlEventBatch, _ kinds: [String]) async -> [ControlEvent] {
        await run(.eventsRead) {
            $0.after = String(batch.next)
            $0.run = batch.run.uuidString
            $0.kinds = kinds
        }.result?.events?.items ?? []
    }

    private func ask(_ text: String) async {
        let response = await run(.assistantAsk) { $0.text = text }
        XCTAssertTrue(response.ok, response.error ?? "")
    }

    private func turnDone(_ count: Int = 1) async {
        let chat = actions.assistant.chat
        await waitFor("\(count) finished turn(s)") {
            chat.entries(last: nil).filter { $0.kind != .user }.count >= count && !chat.running
        }
    }

    func testShowReadsBackAndClearsSelection() async throws {
        let selected = try session()
        try store().selectSession(selected.id)
        let batch = try await anchor()

        let show = await run(.assistantShow)
        XCTAssertTrue(show.ok)

        let shown = try await tree()
        XCTAssertEqual(shown.assistantShown, true)
        XCTAssertNil(try store().selectedSessionID)
        let selections = await events(after: batch, ["session.selected"])
        XCTAssertEqual(selections.count, 1)
        XCTAssertNil(selections.first?.session)

        let go = await run(.sessionGo) { $0.to = "first" }
        XCTAssertTrue(go.ok)
        let after = try await tree()
        XCTAssertNil(after.assistantShown)
    }

    func testSelectingThePreviouslySelectedSessionHidesTheChat() throws {
        let selected = try session()
        try store().selectSession(selected.id)
        actions.showAssistant(in: try store())

        try store().selectSession(selected.id)

        XCTAssertFalse(try store().assistantShown)
        XCTAssertEqual(try store().selectedSessionID, selected.id)
    }

    func testShowClosesTheDashboard() async throws {
        let member = try session()
        let windowID = try XCTUnwrap(library.activeWindowID)
        let dashboard = DashboardController()
        DashboardControllerRegistry.shared.register(windowID, controller: dashboard)
        defer { DashboardControllerRegistry.shared.unregister(windowID) }
        dashboard.open(members: [DashboardMember(session: member.id, surface: .primary)])
        let open = try await tree()
        XCTAssertFalse(open.dashboardMembers?.isEmpty ?? true)

        let show = await run(.assistantShow)
        XCTAssertTrue(show.ok)

        let closed = try await tree()
        XCTAssertTrue(closed.dashboardMembers?.isEmpty ?? true)
    }

    func testADashboardOverTheChatTakesItOffScreen() async throws {
        let member = try session()
        let windowID = try XCTUnwrap(library.activeWindowID)
        let dashboard = DashboardController()
        DashboardControllerRegistry.shared.register(windowID, controller: dashboard)
        defer { DashboardControllerRegistry.shared.unregister(windowID) }
        let show = await run(.assistantShow)
        XCTAssertTrue(show.ok)
        XCTAssertTrue(server.assistantOnScreen { _ in true })

        dashboard.open(members: [DashboardMember(session: member.id, surface: .primary)])
        XCTAssertFalse(server.assistantOnScreen { _ in true })
    }

    func testChatSurvivesBackgroundCloseAndModeSwitch() async throws {
        let background = try session()
        _ = try session()
        let steps = [
            await run(.assistantShow),
            await run(.sessionClose, target: background.id.uuidString),
            await run(.sessionNew) { $0.noSelect = true },
            await run(.sidebarMode) { $0.mode = "flagged" },
        ]
        XCTAssertEqual(steps.map(\.ok), [true, true, true, true], "\(steps.map(\.error))")

        let after = try await tree()
        XCTAssertEqual(after.assistantShown, true)
        XCTAssertNil(try store().selectedSessionID)
    }

    func testRemoteRowIsNoPeer() async throws {
        let local = try session()
        let remote = try session(remote: "mac2")

        let nodes = try await tree().workspaces.flatMap(\.sessions)
        XCTAssertNotNil(nodes.first { $0.id == local.id.uuidString }?.handle)
        XCTAssertNil(nodes.first { $0.id == remote.id.uuidString }?.handle)

        let sent = await run(.assistantSend) {
            $0.recipients = [remote.id.uuidString]
            $0.text = "hi"
        }
        XCTAssertFalse(sent.ok)
        XCTAssertTrue(sent.error?.contains(remote.id.uuidString) == true, sent.error ?? "")
        XCTAssertTrue(actions.assistant.chat.entries(last: nil).filter { $0.kind == .sent }.isEmpty)
    }

    func testAskRunsATurnThroughTheFakeProvider() async throws {
        let batch = try await anchor()

        await ask("hi")
        await turnDone()

        let read = await entries()
        XCTAssertEqual(read.last?.kind, .assistant)
        let after = try await tree()
        XCTAssertEqual(after.assistant?.running, false)
        let kinds = await events(after: batch, ["assistant.message"]).map(\.payload.kind)
        XCTAssertEqual(kinds, ["user", "assistant"])
    }

    func testProviderDeathYieldsOneErrorEntry() async throws {
        await ask("crash")
        await turnDone()
        let crashed = await entries()
        XCTAssertEqual(crashed.filter { $0.kind == .error }.count, 1)

        let switched = await run(.assistantProvider) { $0.provider = "codex" }
        XCTAssertTrue(switched.ok, switched.error ?? "")
        await ask("x")
        await turnDone(2)

        let read = await entries()
        let answer = try XCTUnwrap(read.last)
        XCTAssertEqual(answer.kind, .assistant)
        XCTAssertTrue(answer.text.hasSuffix("x"), answer.text)
        XCTAssertTrue(actions.assistant.chat.resume[.codex]?.hasPrefix("fake-") == true, "codex answered through exec")
    }

    func testClearStopsTheProcessAndEmitsCleared() async throws {
        await ask("hi")
        await turnDone()
        XCTAssertNotNil(actions.assistant.runner.pid)
        let batch = try await anchor()

        let clear = await run(.assistantClear)
        XCTAssertTrue(clear.ok)

        await waitFor("the provider to stop", seconds: 5) { actions.assistant.runner.pid == nil }
        let cleared = await events(after: batch, ["assistant.cleared"])
        XCTAssertEqual(cleared.count, 1)
        let read = await entries()
        XCTAssertTrue(read.isEmpty)
    }

    func testChatPersistsAndReloads() async throws {
        await ask("hi")
        await turnDone()

        let reloaded = AssistantModel(stateDirectory: stateDir, standIn: nil)

        XCTAssertEqual(reloaded.chat.entries(last: nil), actions.assistant.chat.entries(last: nil))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateDir.appendingPathComponent("assistant/chat.jsonl").path))
    }

    func testReplyWhileTheChatIsOnScreenIsNotUnread() async throws {
        actions.assistant.runner.stopForQuit()
        actions.assistant = AssistantModel(stateDirectory: stateDir, standIn: ["/bin/bash", "-c", "exec sleep 600"])
        server.installAssistant()
        let sender = try session()

        actions.assistant.onScreen = { true }
        let first = await run(.assistantReply, target: sender.id.uuidString) { $0.text = "done" }
        XCTAssertTrue(first.ok, first.error ?? "")
        let seen = try await tree()
        XCTAssertEqual(seen.assistant?.unread, 0)

        actions.assistant.onScreen = { false }
        let second = await run(.assistantReply, target: sender.id.uuidString) { $0.text = "again" }
        XCTAssertTrue(second.ok, second.error ?? "")
        let unseen = try await tree()
        XCTAssertEqual(unseen.assistant?.unread, 1)
    }

    func testAReplyMissedOffScreenIsSeenWhenAChatWindowBecomesKey() async throws {
        actions.assistant.runner.stopForQuit()
        actions.assistant = AssistantModel(stateDirectory: stateDir, standIn: ["/bin/bash", "-c", "exec sleep 600"])
        server.installAssistant()
        let sender = try session()
        actions.assistant.onScreen = { false }
        let reply = await run(.assistantReply, target: sender.id.uuidString) { $0.text = "done" }
        XCTAssertTrue(reply.ok, reply.error ?? "")
        let unseen = try await tree()
        XCTAssertEqual(unseen.assistant?.unread, 1)

        actions.assistant.onScreen = { true }
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: nil)
        await waitFor("unread cleared", seconds: 5) { actions.assistant.unread == 0 }

        let seen = try await tree()
        XCTAssertEqual(seen.assistant?.unread, 0)
    }
}
