import XCTest

@MainActor
final class AssistantUITests: ControlAPITestCase {
    private static let fake = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("linux/tests/fixtures/fake-provider.sh").path

    override var launchEnvironmentOverrides: [String: String] { ["ELIS_ASSISTANT_PROVIDER_CMD": "/bin/bash \(Self.fake)"] }

    private static let marker = "90210-123"
    private var composer: XCUIElement { app.textViews["assistant-composer"] }

    private func showChat() {
        let row = app.descendants(matching: .any)["assistant-row"].firstMatch
        XCTAssertTrue(row.waitForHittable(timeout: 10), "the Elis row should be hittable")
        row.click()
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "the chat's composer should show")
    }

    func testChatAnswersAndTheTerminalGetsNothing() throws {
        let session = try activeSessionID()
        showChat()
        // digits only: on this desktop typeText has delivered letters as Command chords (ui-tests.md)
        app.typeText(Self.marker)
        app.typeKey(.return, modifierFlags: [])

        let answer = app.staticTexts.matching(NSPredicate(format: "value CONTAINS 'pid' AND value CONTAINS %@", Self.marker)).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 30),
                      "the fake provider's answer should show in the chat; transcript: \((try? sendCommand(#"{"cmd":"assistant.read"}"#)) ?? [:]); "
                          + app.debugDescription)
        let response = try sendCommand(#"{"cmd":"session.text","target":"\#(session)"}"#)
        let text = try XCTUnwrap((response["result"] as? [String: Any])?["text"] as? String, "session.text: \(response)")
        XCTAssertFalse(text.contains(Self.marker), "the terminal under the chat got the typed text: \(text)")
    }

    func testDraggingASessionRowAddsItsChip() throws {
        let handle = try XCTUnwrap(try sessionNode(id: activeSessionID())["handle"] as? String, "the session's handle")
        showChat()
        let row = app.staticTexts["session-row"].firstMatch
        XCTAssertTrue(row.waitForHittable(timeout: 10), "the session row should be hittable to drag")
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = composer.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        start.click(forDuration: 0.7, thenDragTo: end, withVelocity: 180, thenHoldForDuration: 0.25)

        XCTAssertTrue(poll(until: (composer.value as? String)?.hasPrefix("@\(handle)") == true, timeout: 10),
                      "the composer should start with @\(handle), got \(String(describing: composer.value))")
    }
}
