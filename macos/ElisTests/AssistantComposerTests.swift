import AppKit
import ElisCore
import XCTest
@testable import Elis

@MainActor
final class AssistantComposerTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var actions: AppActions!
    private var server: ControlServer!
    private var window: NSWindow!
    private var composer: AssistantComposerTextView!
    private var surfaces: [GhosttySurfaceView] = []

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory.appendingPathComponent("elis-composer-\(UUID().uuidString)", isDirectory: true)
        library = WindowLibrary(directory: stateDir)
        actions = AppActions(library: library)
        server = ControlServer(
            library: library, actions: actions,
            settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
            identity: AppIdentity(version: "9.9.9", commit: "testsha"),
            socketPath: stateDir.appendingPathComponent("control.sock").path)
        server.installAssistant()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        composer = AssistantComposerTextView(model: actions.assistant, store: try store(), state: AssistantComposerState())
        composer.frame = NSRect(x: 0, y: 0, width: 600, height: 22)
        window.contentView?.addSubview(composer)
    }

    override func tearDown() async throws {
        surfaces.forEach { $0.retireSurface() }
        surfaces = []
        window.close()
        composer = nil
        window = nil
        server = nil
        actions = nil
        library = nil
        try? FileManager.default.removeItem(at: stateDir)
        try await super.tearDown()
    }

    private func store() throws -> AppStore { try XCTUnwrap(library.activeStore) }

    private func session(remote: String? = nil) throws -> Session {
        let store = try store()
        return try XCTUnwrap(store.addSession(toWorkspace: try XCTUnwrap(store.currentWorkspaceID), cwd: "/tmp", remoteHost: remote))
    }

    private func press(_ modifiers: NSEvent.ModifierFlags = [], key: String = "\r", code: UInt16 = 36) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, characters: key,
                                                   charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
        composer.keyDown(with: event)
    }

    private func terminal() -> GhosttySurfaceView {
        let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(), command: "/bin/cat", env: [:], backedByZmx: false)
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 100)
        window.contentView?.addSubview(view)
        view.createSurface()
        surfaces.append(view)
        return view
    }

    private func splitSession() throws -> (Session, GhosttySurfaceView, GhosttySurfaceView) {
        let session = try session()
        let main = terminal()
        let split = terminal()
        split.isSplitPane = true
        main.session = session
        split.session = session
        session.surface = main
        session.splitSurface = split
        session.splitPaneIdentity = UUID()
        session.hasSplit = true
        return (session, main, split)
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(600)) }

    private func waitFor(_ what: String, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "timed out waiting for \(what)")
    }

    private func drag(_ id: UUID) -> SidebarFakeDrag {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(id.uuidString, forType: sessionPasteboardType)
        item.setString(id.uuidString, forType: .string)
        pasteboard.writeObjects([item])
        return SidebarFakeDrag(pasteboard, over: composer)
    }

    func testReturnSendsAndShiftReturnInsertsANewline() async throws {
        var sent: [ControlRequest] = []
        actions.assistant.perform = { request in
            sent.append(request)
            return ControlResponse(ok: true)
        }
        composer.insertText("hi", replacementRange: composer.selectedRange())
        try press()
        await waitFor("the field to empty") { composer.string.isEmpty }
        XCTAssertEqual(sent.map(\.cmd), [.assistantAsk])
        XCTAssertEqual(sent.first?.args?.text, "hi")

        composer.insertText("a", replacementRange: composer.selectedRange())
        try press(.shift)
        XCTAssertEqual(composer.string, "a\n")
        XCTAssertEqual(sent.count, 1)
    }

    func testRemoteRowDropIsRefused() throws {
        let remote = try session(remote: "far")
        XCTAssertEqual(composer.draggingEntered(drag(remote.id)), [])
        XCTAssertEqual(composer.string, "")

        let local = try session()
        let handle = try XCTUnwrap(AssistantDirectory(server.assistantPeers() ?? []).handle(of: local.id.uuidString))
        let info = drag(local.id)
        XCTAssertEqual(composer.draggingEntered(info), .copy)
        XCTAssertTrue(composer.performDragOperation(info))
        XCTAssertEqual(composer.string, "@\(handle) ")
    }

    func testAnAnswersReplyFrameRendersAsATagWithoutTheSessionID() {
        let id = "A8BA15A4-73FE-45D7-89A9-9D764EDF9389"
        let directory = AssistantDirectory([AssistantPeer(sessionID: id, window: "w", workspaceID: "ws", workspaceName: "elis",
                                                          name: "sidebar-filter")])
        let marked = AssistantMarkdown.mark("[reply from @side-filter \(id)] The chip is **wired**, ask \(id).", in: directory)
        let shown = AssistantMarkdown.blocks(marked.source).map { String($0.content.characters) }.joined()

        XCTAssertFalse(shown.contains(id), shown)
        XCTAssertFalse(shown.contains("reply from"), shown)
        XCTAssertTrue(shown.contains("The chip is wired, ask "), shown)
        XCTAssertEqual(marked.mentions, Array(repeating: .mention(sessionID: id, handle: "side-filter"), count: 2))
    }

    func testAnAnswerLinkOpensOnlyAWebOrMailScheme() throws {
        let blocks = AssistantMarkdown.blocks("[a](file:///Applications/Calculator.app) [b](x-elis://run) [c](https://example.com)")
        let links = blocks.flatMap { $0.content.runs.compactMap(\.link) }
        XCTAssertEqual(links.map(\.absoluteString), ["file:///Applications/Calculator.app", "x-elis://run", "https://example.com"])
        XCTAssertEqual(links.map(AssistantMarkdown.opens), [false, false, true])
    }

    func testEditNotesUserActivity() async throws {
        let idle = { [server] () async -> Int? in await server?.dispatch(ControlRequest(cmd: .tree)).result?.tree?.idleMs }
        let before = await idle()
        XCTAssertTrue(before == nil || before! >= 1000, "idleMs \(String(describing: before)) before any edit")
        composer.insertText("x", replacementRange: composer.selectedRange())
        let after = await idle()
        XCTAssertLessThan(try XCTUnwrap(after), 1000)
    }

    func testASplitExitUnderTheChatLeavesTheComposerFocused() async throws {
        let (session, _, split) = try splitSession()
        let store = try store()
        actions.showAssistant(in: store)
        window.makeFirstResponder(composer)

        elisApp.handlePaneExit(split, store: store, sessionID: session.id, library: library)
        await settle()

        XCTAssertTrue(window.firstResponder === composer, "first responder \(String(describing: window.firstResponder))")
    }

    func testTheSelectedSessionsSplitExitFocusesItsSurvivingPane() async throws {
        let (session, main, split) = try splitSession()
        let store = try store()
        _ = store.selectSession(session.id)
        window.makeFirstResponder(composer)

        elisApp.handlePaneExit(split, store: store, sessionID: session.id, library: library)

        await waitFor("the surviving pane to take focus") { window.firstResponder === main }
        await settle()
    }

    func testTabWithoutACompletionKeepsTheComposerFocused() throws {
        let other = NSTextField(frame: NSRect(x: 0, y: 100, width: 100, height: 22))
        window.contentView?.addSubview(other)
        composer.nextKeyView = other
        other.nextKeyView = composer
        window.makeFirstResponder(composer)

        try press(key: "\t", code: 48)
        XCTAssertTrue(window.firstResponder === composer)
        try press(.shift, key: "\u{19}", code: 48)
        XCTAssertTrue(window.firstResponder === composer)
        XCTAssertEqual(composer.string, "")
    }

    private func type(_ text: String) { composer.insertText(text, replacementRange: composer.selectedRange()) }

    func testCompletionKeysMoveAndInsertTheHighlightedTag() throws {
        _ = try session()
        _ = try session()
        window.makeFirstResponder(composer)
        type("@")
        let rows = composer.state.completion.map(\.tag)
        XCTAssertGreaterThan(rows.count, 2)
        try press(key: "\u{F701}", code: 125)
        try press(key: "\u{F701}", code: 125)
        try press(key: "\u{F700}", code: 126)
        XCTAssertEqual(composer.state.highlighted, 1)
        try press()
        XCTAssertEqual(composer.string, "\(rows[1]) ")
        XCTAssertTrue(composer.state.completion.isEmpty)

        type("@")
        try press(key: "\t", code: 48)
        XCTAssertEqual(composer.string, "\(rows[1]) \(rows[0]) ")
    }

    func testEscapeClosesTheCompletionAndKeepsTheText() throws {
        _ = try session()
        window.makeFirstResponder(composer)
        type("@")
        XCTAssertFalse(composer.state.completion.isEmpty)
        try press(key: "\u{1b}", code: 53)
        XCTAssertTrue(composer.state.completion.isEmpty)
        XCTAssertEqual(composer.string, "@")
    }

    func testBackspaceAfterAChipRemovesTheWholeChip() throws {
        window.makeFirstResponder(composer)
        type("hi @all")
        try press(key: "\u{7f}", code: 51)
        XCTAssertEqual(composer.string, "hi ")
    }

    func testAWorkspaceDropAddsItsWorkspaceTag() throws {
        let local = try session()
        let peers = server.assistantPeers() ?? []
        let workspaceID = try XCTUnwrap(peers.first { $0.sessionID == local.id.uuidString }?.workspaceID)
        let handle = try XCTUnwrap(AssistantDirectory(peers).workspaceHandle(of: workspaceID))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pasteboard.clearContents()
        pasteboard.setString(workspaceID, forType: workspacePasteboardType)
        let info = SidebarFakeDrag(pasteboard, over: composer)
        XCTAssertEqual(composer.draggingEntered(info), .copy)
        XCTAssertTrue(composer.performDragOperation(info))
        XCTAssertEqual(composer.string, "@ws:\(handle) ")
    }

    func testTheFocusRequestReachesOnlyItsOwnStoresComposer() throws {
        window.makeFirstResponder(nil)
        NotificationCenter.default.post(name: .elisFocusAssistantComposer, object: AppStore())
        XCTAssertFalse(window.firstResponder === composer)
        NotificationCenter.default.post(name: .elisFocusAssistantComposer, object: try store())
        XCTAssertTrue(window.firstResponder === composer)
    }

    func testAnOpenRenameFieldKeepsTheKeyboard() throws {
        window.makeFirstResponder(nil)
        actions.renamePending = true
        actions.showAssistant(in: try store())
        composer.takeFocus()
        XCTAssertFalse(window.firstResponder === composer)
        actions.renamePending = false
        composer.takeFocus()
        XCTAssertTrue(window.firstResponder === composer)
    }

    func testUndoAfterASendLeavesTheFieldEmpty() async throws {
        let undo = UndoManager()
        let owner = UndoOwner(undo)
        window.delegate = owner
        defer { window.delegate = nil }
        actions.assistant.perform = { _ in ControlResponse(ok: true) }
        window.makeFirstResponder(composer)
        type("hi")
        try press()
        await waitFor("the field to empty") { composer.string.isEmpty }
        XCTAssertTrue(composer.undoManager === undo)
        while undo.canUndo { undo.undo() }
        XCTAssertEqual(composer.string, "")
    }

    func testDetectionThatFindsNothingStopsDetecting() async {
        final class Flag: @unchecked Sendable { var raised = false }
        let model = AssistantModel(stateDirectory: nil, standIn: nil)
        model.detect = {}
        XCTAssertFalse(model.detected)
        let changed = Flag()
        withObservationTracking { _ = model.detecting } onChange: { changed.raised = true }
        await model.detectProviders()
        XCTAssertTrue(changed.raised)
        XCTAssertFalse(model.detecting)
    }

    func testTheAnswerViewRefusesAFileOrCustomSchemeLink() {
        var accepted: [Bool] = []
        for link in ["file:///Applications/Calculator.app", "x-elis://run"] {
            AssistantMarkdown.openURL(URL(string: link)!) { accepted.append($0) }
        }
        XCTAssertEqual(accepted, [false, false])
    }

    func testACardForAnEndedSessionHasNoTag() throws {
        let local = try session()
        let directory = AssistantDirectory(server.assistantPeers() ?? [])
        let live = AssistantView.cardPeer(local.id.uuidString, in: directory)
        XCTAssertEqual(live.tag, directory.handle(of: local.id.uuidString).map { "@\($0)" })
        XCTAssertNotNil(live.tag)
        let ended = AssistantView.cardPeer(UUID().uuidString, in: directory)
        XCTAssertNil(ended.tag)
        XCTAssertEqual(ended.name, "ended session")
    }
}

/// A private undo stack, so undoing everything never reaches the app's shared one.
private final class UndoOwner: NSObject, NSWindowDelegate {
    let undo: UndoManager
    init(_ undo: UndoManager) { self.undo = undo }
    func windowWillReturnUndoManager(_: NSWindow) -> UndoManager? { undo }
}
