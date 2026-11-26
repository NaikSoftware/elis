import XCTest
@testable import Elis
import ElisCore

@MainActor
final class ControlServerProgressTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var server: ControlServer!

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("elis-control-progress-tests-\(UUID().uuidString)", isDirectory: true)
        library = WindowLibrary(directory: stateDir)
        server = ControlServer(
            library: library,
            actions: AppActions(library: library),
            settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
            identity: AppIdentity(version: "9.9.9", commit: "testsha"),
            socketPath: stateDir.appendingPathComponent("control.sock").path
        )
    }

    override func tearDown() async throws {
        server = nil
        library = nil
        try? FileManager.default.removeItem(at: stateDir)
        stateDir = nil
        try await super.tearDown()
    }

    private func progress(_ value: String, _ id: UUID) async -> ControlResponse {
        await server.dispatch(ControlRequest(cmd: .sessionProgress, target: id.uuidString, args: ControlArgs(progress: value)))
    }

    private func node(_ id: UUID) async throws -> ControlProgressNode? {
        let response = await server.dispatch(ControlRequest(cmd: .tree))
        let tree = try XCTUnwrap(response.result?.tree)
        return try XCTUnwrap(tree.workspaces.flatMap(\.sessions).first { $0.id == id.uuidString }).progress
    }

    func testSessionProgressSetsAndClears() async throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.addSession(toWorkspace: try XCTUnwrap(store.currentWorkspaceID), cwd: NSHomeDirectory()))

        let set = await progress("3/7", session.id)
        XCTAssertTrue(set.ok, set.error ?? "")
        XCTAssertEqual(set.result?.id, session.id.uuidString)
        let shown = try await node(session.id)
        XCTAssertEqual(shown, ControlProgressNode(value: "3/7", fraction: 3.0 / 7, source: "control"))

        let refused = await progress("8/7", session.id)
        XCTAssertEqual(refused, ControlResponse(ok: false, error: "invalid progress"))
        let kept = try await node(session.id)
        XCTAssertEqual(kept?.value, "3/7")

        let cleared = await progress("clear", session.id)
        XCTAssertTrue(cleared.ok, cleared.error ?? "")
        let gone = try await node(session.id)
        XCTAssertNil(gone)
    }
}
