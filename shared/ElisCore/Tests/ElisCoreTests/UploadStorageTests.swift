import Foundation
import Testing
@testable import ElisCore

@MainActor
struct UploadStorageTests {
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ups-\(UUID().uuidString)")

        deinit { try? FileManager.default.removeItem(at: root) }

        func files(_ session: String) -> [String] {
            let folder = root.appendingPathComponent("uploads/\(session)")
            return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        }

        func write(_ relative: String, age: TimeInterval, now: Date) throws {
            let url = root.appendingPathComponent("uploads/\(relative)")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
    }

    private let now = ISO8601DateFormatter().date(from: "2026-11-24T10:30:00Z")!

    @Test func safeNameKeepsOnlyPortableCharacters() {
        #expect(UploadStorage.safeName("-my photo'1.png") == "_my_photo_1.png")
        #expect(UploadStorage.safeName(".env") == "_env")
        #expect(UploadStorage.safeName("ñandú/ü.txt") == "_and___.txt")
        #expect(UploadStorage.safeName("") == "file")
        #expect(UploadStorage.safeName(String(repeating: "a", count: 150)).count == 100)
    }

    @Test func fileNameStampsUTC() {
        #expect(UploadStorage.fileName("-my photo'1.png", now: now) == "20261124-103000-_my_photo_1.png")
    }

    @Test func reserveClaimsAFreshNameEachTime() throws {
        let fixture = Fixture()
        let first = try UploadStorage.reserve(stateDir: fixture.root, sessionID: "S1", name: "a.png", now: now)
        let second = try UploadStorage.reserve(stateDir: fixture.root, sessionID: "S1", name: "a.png", now: now)
        #expect(first.lastPathComponent == "20261124-103000-a.png")
        #expect(second.lastPathComponent == "20261124-103000-a-2.png")
        #expect(first.deletingLastPathComponent().path == fixture.root.appendingPathComponent("uploads/S1").path)
        #expect(fixture.files("S1") == ["20261124-103000-a-2.png", "20261124-103000-a.png"])
    }

    @Test func finishLeavesOnlyTheFinalFile() throws {
        let fixture = Fixture()
        let path = try UploadStorage.reserve(stateDir: fixture.root, sessionID: "S1", name: "a.txt", now: now)
        let sink = try UploadSink(path: path)
        try sink.write(Data("hello".utf8))
        #expect(try sink.finish() == path)
        #expect(fixture.files("S1") == ["20261124-103000-a.txt"])
        #expect(try String(contentsOf: path, encoding: .utf8) == "hello")
    }

    @Test func abandonLeavesNothing() throws {
        let fixture = Fixture()
        let path = try UploadStorage.reserve(stateDir: fixture.root, sessionID: "S1", name: "a.txt", now: now)
        let sink = try UploadSink(path: path)
        try sink.write(Data("partial".utf8))
        sink.abandon()
        #expect(fixture.files("S1").isEmpty)
    }

    @Test func sweepDropsUnknownFoldersAndOldFiles() throws {
        let fixture = Fixture()
        try fixture.write("gone/a", age: 0, now: now)
        try fixture.write("kept/old", age: 8 * 86_400, now: now)
        try fixture.write("kept/new", age: 86_400, now: now)
        UploadStorage.sweep(stateDir: fixture.root, keep: ["kept"], now: now)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("uploads/gone").path))
        #expect(fixture.files("kept") == ["new"])
    }

    @Test func sweepWithoutAKeepSetOnlyPrunesByAge() throws {
        let fixture = Fixture()
        try fixture.write("other/old", age: 8 * 86_400, now: now)
        try fixture.write("other/new", age: 0, now: now)
        UploadStorage.sweep(stateDir: fixture.root, keep: nil, now: now)
        #expect(fixture.files("other") == ["new"])
    }

    @Test func keepHoldsClaimedAndRecentClosedSessions() {
        let open = UUID(), closed = UUID(), companion = UUID(), member = UUID()
        let claim = ZmxPaneClaim(paneIdentity: UUID(), pane: .left, pendingClose: false, windowID: UUID(), windowName: nil,
                                 windowState: .open, workspaceID: nil, workspaceName: nil, sessionID: open, sessionName: nil)
        let sessionEntry = RecentClosedItem(kind: .session, title: "s", subtitle: nil, session: RecentClosedSession(
            workspaceID: UUID(), workspaceName: "w", workspaceIndex: 0, sessionIndex: 0,
            snapshot: SessionSnapshot(id: closed, customName: nil, cwd: "/tmp"), companions: [SessionSnapshot(id: companion, customName: nil, cwd: "/tmp")]))
        let workspaceEntry = RecentClosedItem(kind: .workspace, title: "w", subtitle: nil, workspace: RecentClosedWorkspace(
            snapshot: WorkspaceSnapshot(id: UUID(), name: "w", sessions: [SessionSnapshot(id: member, customName: nil, cwd: "/tmp")]),
            selectedSessionID: nil))
        let keep = UploadStorage.keep(claims: ZmxClaimWalk(claims: [claim], complete: true), recent: [sessionEntry, workspaceEntry])
        #expect(keep == Set([open, closed, companion, member].map(\.uuidString)))
        #expect(keep?.contains(sessionEntry.id.uuidString) == false)
        #expect(UploadStorage.keep(claims: ZmxClaimWalk(claims: [claim], complete: false), recent: []) == nil)
    }

    @Test func answerReservesALocalPath() throws {
        let fixture = Fixture()
        let session = Session(initialCwd: "/tmp")
        let response = UploadStorage.answer(for: session, stateDir: fixture.root, name: "a.png", now: now)
        let expected = fixture.root.appendingPathComponent("uploads/\(session.id.uuidString)/20261124-103000-a.png").path
        #expect(response.ok)
        #expect(response.result?.upload == ControlUpload(path: expected))
    }

    @Test func answerNamesTheOriginForAnAttachedRow() {
        let fixture = Fixture()
        let session = Session(initialCwd: "/tmp", remoteHost: "mini", remoteSessionID: "origin-1")
        let response = UploadStorage.answer(for: session, stateDir: fixture.root, name: "a.png", now: now)
        #expect(response.result?.upload == ControlUpload(host: "mini", session: "origin-1"))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("uploads").path))
    }

    @Test func answerRefusesAPageRow() {
        let fixture = Fixture()
        for session in [Session(initialCwd: "/tmp", content: .page),
                        Session(initialCwd: "/tmp", remoteHost: "mini", remoteSessionID: "o", content: .page)] {
            let response = UploadStorage.answer(for: session, stateDir: fixture.root, name: "a.png", now: now)
            #expect(response == ControlResponse(ok: false, error: "session.upload: not available on a page session"))
        }
    }

    @Test func uploadResultRoundTrips() throws {
        var args = ControlArgs(name: "a.png")
        args.size = 12
        let request = ControlRequest(cmd: .sessionUpload, target: "s", args: args)
        #expect(try JSONDecoder().decode(ControlRequest.self, from: JSONEncoder().encode(request)) == request)
        var result = ControlResult()
        result.upload = ControlUpload(path: "/p")
        let json = try String(decoding: JSONEncoder().encode(ControlResponse(ok: true, result: result)), as: UTF8.self)
        #expect(json.contains(#""upload":{"path":"\/p"}"#))
    }
}
