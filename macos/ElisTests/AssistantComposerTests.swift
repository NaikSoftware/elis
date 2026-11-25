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

    private func press(_ modifiers: NSEvent.ModifierFlags = []) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, characters: "\r",
                                                   charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        composer.keyDown(with: event)
    }

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

    func testEditNotesUserActivity() async throws {
        let idle = { [server] () async -> Int? in await server?.dispatch(ControlRequest(cmd: .tree)).result?.tree?.idleMs }
        let before = await idle()
        XCTAssertTrue(before == nil || before! >= 1000, "idleMs \(String(describing: before)) before any edit")
        composer.insertText("x", replacementRange: composer.selectedRange())
        let after = await idle()
        XCTAssertLessThan(try XCTUnwrap(after), 1000)
    }
}
