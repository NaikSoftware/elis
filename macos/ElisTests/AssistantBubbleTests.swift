import AppKit
import ElisCore
import SwiftUI
import XCTest
@testable import Elis

@MainActor
final class AssistantBubbleTests: XCTestCase {
    private var stateDir: URL!
    private var window: NSWindow?
    private var model: AssistantModel!

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory.appendingPathComponent("elis-bubble-\(UUID().uuidString)", isDirectory: true)
        model = AssistantModel(stateDirectory: stateDir, standIn: ["/bin/bash", "-c", "exec sleep 600"])
    }

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
        model.runner.stopForQuit()
        try? FileManager.default.removeItem(at: stateDir)
        try await super.tearDown()
    }

    func testABubbleHugsShortTextAndCapsLongTextAtTheColumnShare() throws {
        let long = String(repeating: "where are you two at, keep it short please ", count: 6)
        model.chat.append(.user, text: "fail", from: nil, now: 0)
        model.chat.append(.user, text: long, from: nil, now: 1)
        model.refresh()
        let labels = try mount()
        XCTAssertEqual(labels.count, 2)
        let short = try XCTUnwrap(labels.first { $0.string == "fail" })
        let wide = try XCTUnwrap(labels.first { $0.string == long })
        let textWidth = ceil(("fail" as NSString).size(withAttributes: [.font: AssistantTagStyle.font]).width)
        XCTAssertEqual(short.frame.width, textWidth, accuracy: 2, "short bubble hugs its text")
        // the column is 680 wide here, so the bubble's text is capped at 76% of it less the 24pt padding
        XCTAssertEqual(wide.frame.width, 680 * 0.76 - 26, accuracy: 2, "long bubble capped")
    }

    func testAMeasuredTaggedLineStaysOneLineInTheLabelsOwnLayout() {
        let label = AssistantTagLabel()
        label.show("@rele-notes open the draft in an overlay", known: ["@rele-notes"])
        let size = label.size(fitting: 491)
        label.frame = NSRect(origin: .zero, size: size)
        label.layout()
        let layoutManager = label.layoutManager!, container = label.textContainer!
        layoutManager.ensureLayout(for: container)
        var lines = 0
        layoutManager.enumerateLineFragments(forGlyphRange: layoutManager.glyphRange(for: container)) { _, _, _, _, _ in lines += 1 }
        XCTAssertEqual(lines, 1, "measured \(size) wraps in the label")
        XCTAssertLessThan(size.width, 491)
    }

    func testHardBrokenLinesHugTheirLongestLine() {
        let label = AssistantTagLabel()
        label.show("short\nthe longest line of the three\n\nend", known: [])
        let longest = ceil(("the longest line of the three" as NSString).size(withAttributes: [.font: AssistantTagStyle.font]).width)

        let size = label.size(fitting: 491)

        XCTAssertEqual(size.width, longest, accuracy: 2)
        XCTAssertEqual(size.height, 80, accuracy: 1)
    }

    private func mount() throws -> [AssistantTagLabel] {
        let library = WindowLibrary(directory: stateDir)
        let store = try XCTUnwrap(library.activeStore)
        let host = NSHostingView(rootView: AssistantView(model: model, store: store, background: .white, dark: false)
            .frame(width: 900, height: 600))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        self.window = window
        let deadline = Date().addingTimeInterval(5)
        var labels: [AssistantTagLabel] = []
        while labels.count < 2, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
            labels = Self.find(in: host)
        }
        return labels
    }

    private static func find(in view: NSView) -> [AssistantTagLabel] {
        (view as? AssistantTagLabel).map { [$0] } ?? view.subviews.flatMap { find(in: $0) }
    }
}
