import AppKit
import SwiftUI
import XCTest
@testable import Elis
import ElisCore

@MainActor
final class SidebarInfoRowTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var actions: AppActions!
    private var window: NSWindow!
    private var outline: SidebarOutlineView!
    private var coordinator: WorkspaceSidebar.Coordinator!
    private var savedDisplay = SessionInfoDisplay.always

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("elis-sidebar-info-tests-\(UUID().uuidString)", isDirectory: true)
        library = WindowLibrary(directory: stateDir)
        actions = AppActions(library: library)
        savedDisplay = GhosttyApp.shared.sessionInfoDisplay
        GhosttyApp.shared.setSessionInfoDisplay(.always)
    }

    override func tearDown() async throws {
        GhosttyApp.shared.setSessionInfoDisplay(savedDisplay)
        window?.orderOut(nil)
        window = nil
        outline = nil
        coordinator = nil
        actions = nil
        library = nil
        try? FileManager.default.removeItem(at: stateDir)
        try await super.tearDown()
    }

    func testARowGrowsWithInfoAndReturnsToPlainHeightOnClear() throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try seed(store)
        buildSidebar(for: store)
        XCTAssertEqual(try height(of: session.id), plainHeight)

        store.setCI(ci(), forSession: session.id)
        coordinator.reconcile()
        XCTAssertEqual(try height(of: session.id), infoHeight)

        store.setCI(nil, forSession: session.id)
        coordinator.reconcile()
        XCTAssertEqual(try height(of: session.id), plainHeight)
    }

    func testOffDrawsNoLine() throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try seed(store)
        store.setCI(ci(), forSession: session.id)
        buildSidebar(for: store)
        XCTAssertEqual(try height(of: session.id), infoHeight)

        GhosttyApp.shared.setSessionInfoDisplay(.off)
        coordinator.reconcile()

        XCTAssertEqual(try height(of: session.id), plainHeight)
    }

    func testFlaggedViewOnlyHidesTheLineInTheTreeAndShowsItInTheFlaggedView() throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try seed(store)
        store.setFlag(true, forSession: session.id)
        store.setCI(ci(), forSession: session.id)
        GhosttyApp.shared.setSessionInfoDisplay(.flagged)
        buildSidebar(for: store)
        XCTAssertEqual(try height(of: session.id), plainHeight)

        store.setSidebarMode(.flagged)
        coordinator.reconcile()
        XCTAssertEqual(try height(of: session.id), infoHeight)

        store.setSidebarMode(.tree)
        coordinator.reconcile()
        XCTAssertEqual(try height(of: session.id), plainHeight)
    }

    func testChangingTheDisplaySettingRedrawsThroughTheAppearanceBroadcast() throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try seed(store)
        store.setCI(ci(), forSession: session.id)
        buildSidebar(for: store)
        XCTAssertEqual(try height(of: session.id), infoHeight)

        GhosttyApp.shared.setSessionInfoDisplay(.off)
        NotificationCenter.default.post(name: .elisAppearanceChanged, object: nil)

        XCTAssertEqual(try height(of: session.id), plainHeight)
    }

    func testASelectedRowKeepsColoredFragmentsAndFollowsTheSelectionForegroundElsewhere() throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try seed(store)
        store.setCI(ci(pr: true), forSession: session.id)
        buildSidebar(for: store)
        let cell = try infoCell(forSession: session.id)

        cell.setColors(selected: true)

        let text = cell.infoField.attributedStringValue
        XCTAssertEqual(rgba(color(in: text, at: 0)), rgba(SidebarCellView.themeTextColor(selected: true).withAlphaComponent(0.85)))
        let row = try XCTUnwrap(outline.rowView(atRow: try row(of: session.id), makeIfNecessary: false) as? SidebarRowView)
        var green = RGBA(r: 0, g: 0, b: 0)
        cell.effectiveAppearance.performAsCurrentDrawingAppearance {
            green = legibleOn(NSColor.tint(.green).rgba, under: row.infoBackdrops,
                              text: SidebarCellView.themeTextColor(selected: true).rgba)
        }
        XCTAssertEqual(rgba(color(in: text, at: text.length - 1)), rgba(NSColor(green)))
    }

    func testAColoredFragmentStaysLegibleOnTheRowsBackdrop() async throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try seed(store)
        XCTAssertTrue(store.setTint(SidebarTint(color: .yellow), forWorkspace: try XCTUnwrap(store.workspaces.last).id))
        let runs = [CIRunState.failed, .running, .passed].map { CIRun(workflow: "\($0)", state: $0, url: "https://github.com/o/r/actions/runs/1") }
        store.setCI(CIStatus(branch: "main", sha: "abc", pr: CIPullRequest(number: 5, title: "t", url: "https://github.com/o/r/pull/5"),
                             runs: runs), forSession: session.id)
        try mountSidebar(for: store)
        try await waitUntil { (try? self.height(of: session.id)) == self.infoHeight }
        let row = try XCTUnwrap(outline.rowView(atRow: try row(of: session.id), makeIfNecessary: false) as? SidebarRowView)
        let backdrops = row.infoBackdrops
        XCTAssertTrue((1...2).contains(backdrops.count), "\(backdrops)")
        XCTAssertNotNil(row.band)

        let text = try infoCell(forSession: session.id).infoField.attributedStringValue
        for glyph in ["✗", "◷", "✓"] {
            let index = (text.string as NSString).range(of: glyph).location
            let shown = try XCTUnwrap(color(in: text, at: index), glyph).rgba
            for backdrop in backdrops {
                let fg = RGBA.luminance(RGBA.composite(shown, over: backdrop)), bg = RGBA.luminance(backdrop)
                XCTAssertGreaterThanOrEqual((max(fg, bg) + 0.05) / (min(fg, bg) + 0.05), 4.5, "\(glyph) \(shown) on \(backdrop)")
            }
            if glyph == "✗" { XCTAssertTrue(shown.r > shown.g && shown.r > shown.b, "red keeps its hue: \(shown)") }
        }
        XCTAssertEqual(rgba(color(in: text, at: 0)), rgba(SidebarCellView.themeTextColor(selected: false)))
    }

    // #1019: the field kept the 13 pt label font, so single-line mode placed the smaller text low and clipped it
    func testTheInfoLineDrawsWholeAtEverySidebarFontSize() throws {
        let saved = Double(GhosttyApp.shared.sidebarFontSize)
        defer { GhosttyApp.shared.setSidebarFontSize(saved) }
        let store = try XCTUnwrap(library.activeStore)
        let session = try seed(store)
        store.setCI(ci(workflow: "gjpqy 0123456789"), forSession: session.id)

        for size in [11, AppSettings.defaultSidebarFontSize, AppSettings.sidebarFontSizeRange.upperBound] {
            GhosttyApp.shared.setSidebarFontSize(size)
            window?.orderOut(nil)
            buildSidebar(for: store)
            let field = try infoCell(forSession: session.id).infoField
            field.superview?.layoutSubtreeIfNeeded()
            let drawn = try XCTUnwrap(field.bitmapImageRepForCachingDisplay(in: field.bounds))
            field.cacheDisplay(in: field.bounds, to: drawn)
            let scale = CGFloat(drawn.pixelsHigh) / drawn.size.height

            let shown = try XCTUnwrap(inkHeight(in: drawn), "font \(size)")
            let whole = try XCTUnwrap(inkHeight(in: try unclipped(field.attributedStringValue, scale: scale)), "font \(size)")
            XCTAssertEqual(shown, whole, accuracy: 1 / scale, "font \(size)")
        }
    }

    func testARedrawKeepsEachFragmentsOwnFont() throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try seed(store)
        store.setCI(ci(pr: true), forSession: session.id)
        buildSidebar(for: store)
        let cell = try infoCell(forSession: session.id)

        cell.setColors(selected: true)

        let text = cell.infoField.attributedStringValue
        let size = SidebarInfoMetrics.font(base: Double(GhosttyApp.shared.sidebarFontSize)).pointSize
        XCTAssertEqual(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, .systemFont(ofSize: size, weight: .semibold))
        XCTAssertEqual(text.attribute(.font, at: text.length - 1, effectiveRange: nil) as? NSFont, .systemFont(ofSize: size, weight: .regular))
    }

    func testARowTintNeverReachesTheInfoLine() throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try seed(store)
        store.setTint(SidebarTint(color: .orange, parts: [.icon, .name]), forSession: session.id)
        store.setCI(ci(pr: true, workflow: nil), forSession: session.id)
        buildSidebar(for: store)
        let cell = try infoCell(forSession: session.id)

        for selected in [false, true] {
            cell.setColors(selected: selected)
            let expected = SidebarCellView.themeTextColor(selected: selected).withAlphaComponent(selected ? 0.85 : 1)
            XCTAssertEqual(rgba(color(in: cell.infoField.attributedStringValue, at: 0)), rgba(expected), "selected: \(selected)")
            XCTAssertEqual(rgba(cell.textField?.textColor), rgba(NSColor.tint(.orange)), "the name keeps its tint")
        }
    }

    func testACIChangeRefreshesTheMountedSidebarAndTheLineTakesItsClick() async throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try seed(store)
        try mountSidebar(for: store)

        store.setCI(ci(), forSession: session.id)
        try await waitUntil { (try? self.height(of: session.id)) == self.infoHeight }
        let field = try infoCell(forSession: session.id).infoField
        XCTAssertEqual(field.stringValue, "✓ build")
        XCTAssertTrue(field.gestureRecognizers.contains { $0 is NSClickGestureRecognizer && $0.delaysPrimaryMouseButtonEvents })

        store.setCI(nil, forSession: session.id)
        try await waitUntil { (try? self.height(of: session.id)) == self.plainHeight }
        XCTAssertEqual(try height(of: session.id), plainHeight)
    }

    func testACILineOpensThePanelOnlyForTheShownSession() async throws {
        let store = try XCTUnwrap(library.activeStore)
        let shown = try seed(store)
        let other = try XCTUnwrap(store.addSession(toWorkspace: try XCTUnwrap(store.workspaces.last).id, cwd: "/tmp/other"))
        store.setCI(ci(), forSession: shown.id)
        store.setCI(ci(), forSession: other.id)
        store.selectSession(shown.id)
        try mountSidebar(for: store, key: true)
        try await waitUntil { (try? self.height(of: other.id)) == self.infoHeight }
        defer { CIStatusLine.panel?.close() }

        try await click(try infoCell(forSession: other.id).infoField)
        XCTAssertEqual(store.selectedSessionID, other.id)
        XCTAssertNil(CIStatusLine.panel)

        try await click(try infoCell(forSession: other.id).infoField)
        XCTAssertNotNil(CIStatusLine.panel)
        CIStatusLine.panel?.close()
        try await waitUntil { CIStatusLine.panel == nil }

        XCTAssertTrue(try infoCell(forSession: shown.id).infoField.accessibilityPerformPress())
        XCTAssertEqual(store.selectedSessionID, shown.id)
        XCTAssertNil(CIStatusLine.panel)
    }

    // regression: a line cleared while another row was being renamed stayed on screen after the rename ended
    func testAnInfoChangeDuringARenameCatchesUpWhenTheRenameEnds() async throws {
        let store = try XCTUnwrap(library.activeStore)
        let renamed = try seed(store)
        let other = try XCTUnwrap(store.addSession(toWorkspace: try XCTUnwrap(store.workspaces.last).id, cwd: "/tmp/other"))
        store.setCI(ci(), forSession: other.id)
        try mountSidebar(for: store)
        try await waitUntil { (try? self.height(of: other.id)) == self.infoHeight }
        let coordinator = try XCTUnwrap(outline.delegate as? WorkspaceSidebar.Coordinator)
        let node = try XCTUnwrap(outline.item(atRow: try row(of: renamed.id)) as? SidebarNode)
        coordinator.renameController.beginEditing(node: node)
        let cell = try XCTUnwrap(outline.view(atColumn: 0, row: try row(of: renamed.id), makeIfNecessary: true) as? NSTableCellView)
        let field = try XCTUnwrap(cell.textField)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)

        store.setCI(nil, forSession: other.id)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(try height(of: other.id), infoHeight)

        XCTAssertTrue(coordinator.renameController.control(field, textView: editor,
                                                           doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        try await waitUntil { (try? self.height(of: other.id)) == self.plainHeight }
        XCTAssertEqual(try height(of: other.id), plainHeight)
        XCTAssertFalse(coordinator.renameController.isEditing)
    }

    private var plainHeight: CGFloat { AppSettings.sidebarRowHeight(fontSize: GhosttyApp.shared.sidebarFontSize) }
    private var infoHeight: CGFloat {
        SidebarInfoMetrics.rowHeight(base: GhosttyApp.shared.sidebarFontSize, density: GhosttyApp.shared.sidebarDensity)
    }

    private func ci(pr: Bool = false, workflow: String? = "build") -> CIStatus {
        CIStatus(branch: "main", sha: "abc", pr: pr ? CIPullRequest(number: 5, title: "t", url: "https://github.com/o/r/pull/5") : nil,
                 runs: workflow.map { [CIRun(workflow: $0, state: .passed, url: "https://github.com/o/r/actions/runs/1")] } ?? [])
    }

    private func seed(_ store: AppStore) throws -> Session {
        let workspace = store.addWorkspace(name: "target")
        return try XCTUnwrap(store.addSession(toWorkspace: workspace.id, cwd: "/tmp/info"))
    }

    private func row(of id: UUID) throws -> Int {
        try XCTUnwrap((0..<outline.numberOfRows).first { row in
            (outline.item(atRow: row) as? SidebarNode).map { $0.kind == .session && $0.id == id } ?? false
        })
    }

    // the cell frame leaves out a group row's edge extras
    private func height(of id: UUID) throws -> CGFloat {
        outline.frameOfCell(atColumn: 0, row: try row(of: id)).height
    }

    private func infoCell(forSession id: UUID) throws -> SidebarInfoCellView {
        try XCTUnwrap(outline.view(atColumn: 0, row: try row(of: id), makeIfNecessary: true) as? SidebarInfoCellView)
    }

    private func color(in text: NSAttributedString, at index: Int) -> NSColor? {
        text.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
    }

    private func unclipped(_ text: NSAttributedString, scale: CGFloat) throws -> NSBitmapImageRep {
        let size = NSSize(width: ceil(text.size().width) + 4, height: ceil(text.size().height) * 3)
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                                 pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        text.draw(at: NSPoint(x: 2, y: size.height / 3))
        return rep
    }

    private func inkHeight(in rep: NSBitmapImageRep) -> CGFloat? {
        let rows = (0..<rep.pixelsHigh).filter { y in
            (0..<rep.pixelsWide).contains { x in (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 }
        }
        guard let first = rows.first, let last = rows.last else { return nil }
        return CGFloat(last - first + 1) * rep.size.height / CGFloat(rep.pixelsHigh)
    }

    private func rgba(_ color: NSColor?) -> [CGFloat] {
        guard let rgb = color?.usingColorSpace(.sRGB) else { return [] }
        return [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent].map { ($0 * 1000).rounded() / 1000 }
    }

    private func mountSidebar(for store: AppStore, key: Bool = false) throws {
        let host = NSHostingView(rootView: WorkspaceSidebar(store: store, actions: actions).frame(width: 240, height: 400))
        let type = key ? KeyWindow.self : NSWindow.self
        window = type.init(contentRect: NSRect(x: 0, y: 0, width: 240, height: 400),
                           styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        outline = try XCTUnwrap(outlineView(in: host))
    }

    private func outlineView(in view: NSView) -> SidebarOutlineView? {
        if let outline = view as? SidebarOutlineView { return outline }
        return view.subviews.lazy.compactMap { self.outlineView(in: $0) }.first
    }

    // the mouse-up is queued first: the outline's tracking loop pulls it, and otherwise the window delivers it
    private func click(_ view: NSView) async throws {
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let event = { (type: NSEvent.EventType) in
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: self.window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: 1))
        }
        NSApp.postEvent(try event(.leftMouseUp), atStart: false)
        window.sendEvent(try event(.leftMouseDown))
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func buildSidebar(for store: AppStore) {
        outline = SidebarOutlineView()
        coordinator = WorkspaceSidebar.Coordinator(store: store, actions: actions)
        outline.dataSource = coordinator
        outline.delegate = coordinator
        outline.headerView = nil
        outline.rowSizeStyle = .custom
        outline.rowHeight = AppSettings.sidebarRowHeight(fontSize: GhosttyApp.shared.sidebarFontSize)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        scroll.documentView = outline
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll

        coordinator.outlineView = outline
        coordinator.renameController.outlineView = outline
        coordinator.seedExpansionFromModel()
        coordinator.reconcile()
    }
}

// the hosted app is never active, so no window becomes key and a click would only activate it
private final class KeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}
