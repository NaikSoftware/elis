import AppKit
import SwiftUI
import XCTest
@testable import Elis
import ElisCore

@MainActor
final class SidebarAssistantRowTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var actions: AppActions!
    private var window: NSWindow!
    private var outline: SidebarOutlineView!
    private var coordinator: WorkspaceSidebar.Coordinator!

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("elis-sidebar-assistant-tests-\(UUID().uuidString)", isDirectory: true)
        library = WindowLibrary(directory: stateDir)
        actions = AppActions(library: library)
    }

    override func tearDown() async throws {
        GhosttyApp.shared.setFlaggedViewLayout(.flat)
        window?.orderOut(nil)
        window = nil
        outline = nil
        coordinator = nil
        actions = nil
        library = nil
        try? FileManager.default.removeItem(at: stateDir)
        try await super.tearDown()
    }

    func testRowIsFirstInEveryMode() throws {
        let (store, first, _) = try seed()
        store.setFlag(true, forSession: first.id)
        try mountSidebar(for: store)
        XCTAssertEqual((outline.item(atRow: 0) as? SidebarNode)?.kind, .assistant, "tree")
        for layout in [FlaggedViewLayout.tree, .flat, .plain] {
            GhosttyApp.shared.setFlaggedViewLayout(layout)
            store.setSidebarMode(.flagged)
            coordinator.reconcile()
            XCTAssertEqual((outline.item(atRow: 0) as? SidebarNode)?.kind, .assistant, "flagged \(layout)")
            store.setSidebarMode(.tree)
            coordinator.reconcile()
        }
    }

    func testClickShowsTheChat() throws {
        let (store, _, _) = try seed()
        try mountSidebar(for: store)

        outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        XCTAssertTrue(store.assistantShown)
        XCTAssertNil(store.selectedSessionID)
        settle()
        XCTAssertEqual(outline.selectedRow, 0)
    }

    func testSessionClickHidesTheChat() throws {
        let (store, first, _) = try seed()
        try mountSidebar(for: store)
        outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        settle()

        let sessionRow = try row(of: first.id)
        outline.selectRowIndexes(IndexSet(integer: sessionRow), byExtendingSelection: false)
        settle()

        XCTAssertFalse(store.assistantShown)
        XCTAssertEqual(store.selectedSessionID, first.id)
        XCTAssertEqual(outline.selectedRowIndexes, IndexSet(integer: sessionRow))
    }

    func testCommandClickNeverAddsTheRowToASessionSelection() throws {
        let (store, first, _) = try seed()
        try mountSidebar(for: store)
        let sessionRow = try row(of: first.id)

        let proposed = coordinator.outlineView(outline, selectionIndexesForProposedSelection: IndexSet([0, sessionRow]))

        XCTAssertEqual(proposed, IndexSet(integer: sessionRow))
    }

    func testReloadWithNilSelectionSelectsNothing() throws {
        let (store, _, _) = try seed()
        try mountSidebar(for: store)
        store.selectedSessionID = nil
        settle()

        coordinator.rebuildAndReload()
        coordinator.syncSelection()

        XCTAssertEqual(outline.selectedRow, -1)
        XCTAssertNil(store.selectedSessionID)
        XCTAssertFalse(store.assistantShown)
    }

    func testRowIsNotDraggableNorADropTarget() throws {
        let (store, first, second) = try seed()
        try mountSidebar(for: store)
        let assistant = try XCTUnwrap(outline.item(atRow: 0) as? SidebarNode)
        XCTAssertNil(coordinator.outlineView(outline, pasteboardWriterForItem: assistant))

        let info = sessionDrag([second.id])
        XCTAssertEqual(coordinator.outlineView(outline, validateDrop: info, proposedItem: assistant,
                                               proposedChildIndex: SidebarDrop.onItemIndex), [])
        XCTAssertEqual(coordinator.outlineView(outline, validateDrop: info, proposedItem: nil, proposedChildIndex: 0), [])

        store.setFlag(true, forSessions: [first.id, second.id])
        store.setSidebarMode(.flagged)
        coordinator.reconcile()
        XCTAssertEqual(coordinator.outlineView(outline, validateDrop: info, proposedItem: nil, proposedChildIndex: 0), [])
        XCTAssertNil(coordinator.menu(forRow: 0))
    }

    func testAFlatListGapDropBelowTheRowLandsFirst() throws {
        let (store, first, second) = try seed()
        store.setFlag(true, forSessions: [first.id, second.id])
        store.setSidebarMode(.flagged)
        try mountSidebar(for: store)
        let info = sessionDrag([second.id])

        XCTAssertEqual(coordinator.outlineView(outline, validateDrop: info, proposedItem: nil, proposedChildIndex: 1), .move)
        XCTAssertTrue(coordinator.outlineView(outline, acceptDrop: info, item: nil, childIndex: 1))

        XCTAssertEqual(store.orderedFlaggedSessions.map(\.id), [second.id, first.id])
    }

    func testUnreadBadgeRepaints() throws {
        let (store, _, _) = try seed()
        try mountSidebar(for: store)

        actions.assistant.chat.append(.reply, text: "done", from: "s", now: 0)
        actions.assistant.refresh()

        let cell = try XCTUnwrap(outline.view(atColumn: 0, row: 0, makeIfNecessary: true) as? SidebarAssistantCellView)
        let deadline = Date().addingTimeInterval(5)
        while cell.badge.count != 1, Date() < deadline { settle() }
        XCTAssertEqual(cell.badge.count, 1, "badge never repainted")
        XCTAssertEqual(cell.accessibilityIdentifier(), "assistant-row")
    }

    private func seed() throws -> (AppStore, Session, Session) {
        let store = try XCTUnwrap(library.activeStore)
        let workspace = store.addWorkspace(name: "work")
        let first = try XCTUnwrap(store.addSession(toWorkspace: workspace.id, cwd: "/tmp/a"))
        let second = try XCTUnwrap(store.addSession(toWorkspace: workspace.id, cwd: "/tmp/b"))
        store.selectSession(first.id)
        return (store, first, second)
    }

    private func sessionDrag(_ ids: [UUID]) -> NSDraggingInfo {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("elis-assistant-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString(ids.map(\.uuidString).joined(separator: "\n"), forType: sessionPasteboardType)
        return SidebarFakeDrag(pasteboard, over: outline)
    }

    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        outline.layoutSubtreeIfNeeded()
    }

    private func row(of id: UUID) throws -> Int {
        try XCTUnwrap((0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? SidebarNode)?.id == id })
    }

    private func mountSidebar(for store: AppStore) throws {
        let host = NSHostingView(rootView: WorkspaceSidebar(store: store, actions: actions).frame(width: 240, height: 400))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        outline = try XCTUnwrap(outlineView(in: host))
        coordinator = try XCTUnwrap(outline.delegate as? WorkspaceSidebar.Coordinator)
    }

    private func outlineView(in view: NSView) -> SidebarOutlineView? {
        if let outline = view as? SidebarOutlineView { return outline }
        return view.subviews.lazy.compactMap { self.outlineView(in: $0) }.first
    }
}
