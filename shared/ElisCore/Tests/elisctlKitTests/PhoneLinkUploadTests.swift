#if !canImport(Musl)
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import Testing
import ElisCore
@testable import elisctlKit

struct PhoneLinkUploadTests {
    @Test func fiveBytesLandOnDisk() throws {
        let link = try Local()
        defer { link.finish() }
        link.phone.deliver(Self.open(3, name: "a b.txt", size: 5))
        #expect(link.reader.opened(from: link.phone, channel: 3) == PhoneLinkOpened())
        link.phone.deliver(PhoneLinkFrame.data(channel: 3, Data("hello".utf8)).encoded())
        #expect(link.close(3) == PhoneLinkClose(reason: "uploaded", path: link.path))
        #expect(FileManager.default.contents(atPath: link.path) == Data("hello".utf8))
        #expect(!FileManager.default.fileExists(atPath: link.path + ".part"))
        let asked = link.fixture.server.requests().first { $0.contains("session.upload") }
        let args = try #require(asked.flatMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }?["args"] as? [String: Any])
        #expect(args["name"] as? String == "a_b.txt")
        #expect(args["size"] as? Int == 5)
    }

    @Test func anEmptyFileCompletesAtOnce() throws {
        let link = try Local()
        defer { link.finish() }
        link.phone.deliver(Self.open(3, size: 0))
        #expect(link.reader.opened(from: link.phone, channel: 3) == PhoneLinkOpened())
        #expect(link.close(3) == PhoneLinkClose(reason: "uploaded", path: link.path))
        #expect(FileManager.default.contents(atPath: link.path) == Data())
    }

    @Test func badOpensAreRefused() throws {
        let link = try Local()
        defer { link.finish() }
        link.phone.deliver(Self.open(3, size: UploadLimits.maxBytes + 1))
        #expect(link.reader.opened(from: link.phone, channel: 3)?.error == "file too large (max 20 MiB)")
        link.phone.deliver(Self.open(4, size: -1))
        #expect(link.reader.opened(from: link.phone, channel: 4)?.error == "malformed open")
        link.phone.deliver(PhoneLinkFrame.json(.open, channel: 5, PhoneLinkOpen(type: "upload", target: "S1", size: 5)).encoded())
        #expect(link.reader.opened(from: link.phone, channel: 5)?.error == "malformed open")
        link.phone.deliver(Self.open(6, size: 5))
        #expect(link.reader.opened(from: link.phone, channel: 6) == PhoneLinkOpened())
        link.phone.deliver(Self.open(7, size: 5))
        #expect(link.reader.opened(from: link.phone, channel: 7)?.error == "an upload is already running")
    }

    @Test func aCloseDuringTheAppsAnswerLeavesNothing() throws {
        let link = try Local()
        defer { link.finish() }
        link.fixture.server.hold("session.upload")
        defer { link.fixture.server.release("session.upload") }
        link.phone.deliver(Self.open(3, size: 5))
        #expect(link.waitAsked())
        link.phone.deliver(PhoneLinkFrame.json(.close, channel: 3, PhoneLinkClose(reason: "cancelled")).encoded())
        link.fixture.server.release("session.upload")
        #expect(link.waitGone())
        #expect(link.reader.pending(link.phone).allSatisfy { $0.channel != 3 })
    }

    @Test func aCloseMidStreamLeavesNothing() throws {
        let link = try Local()
        defer { link.finish() }
        link.phone.deliver(Self.open(3, size: 5))
        #expect(link.reader.opened(from: link.phone, channel: 3) == PhoneLinkOpened())
        link.phone.deliver(PhoneLinkFrame.data(channel: 3, Data("he".utf8)).encoded())
        #expect(link.reader.next(from: link.phone, channel: 3, kind: .credit)?.creditBytes == 2)
        link.phone.deliver(PhoneLinkFrame.json(.close, channel: 3, PhoneLinkClose(reason: "cancelled")).encoded())
        #expect(link.waitGone())
    }

    @Test func aLostLinkMidStreamLeavesNothing() throws {
        let link = try Local()
        defer {
            link.fixture.stop()
            try? FileManager.default.removeItem(atPath: link.dir)
        }
        link.phone.deliver(Self.open(3, size: 5))
        #expect(link.reader.opened(from: link.phone, channel: 3) == PhoneLinkOpened())
        link.phone.deliver(PhoneLinkFrame.data(channel: 3, Data("he".utf8)).encoded())
        #expect(link.reader.next(from: link.phone, channel: 3, kind: .credit)?.creditBytes == 2)
        link.phone.peerLeft()
        #expect(link.waitGone())
    }

    @Test func bytesPastTheWindowOverflow() throws {
        let link = try Local()
        defer { link.finish() }
        link.phone.deliver(Self.open(3, size: 20000))
        #expect(link.reader.opened(from: link.phone, channel: 3) == PhoneLinkOpened())
        link.phone.deliver(PhoneLinkFrame.data(channel: 3, Data(count: PhoneLinkUpload.window)).encoded()
            + PhoneLinkFrame.data(channel: 3, Data([1])).encoded())
        #expect(link.close(3) == PhoneLinkClose(reason: "input overflow"))
        #expect(link.waitGone())
    }

    @Test func bytesPastTheSizeOverflow() throws {
        let link = try Local()
        defer { link.finish() }
        link.phone.deliver(Self.open(3, size: 5))
        #expect(link.reader.opened(from: link.phone, channel: 3) == PhoneLinkOpened())
        link.phone.deliver(PhoneLinkFrame.data(channel: 3, Data("hello!".utf8)).encoded())
        #expect(link.close(3) == PhoneLinkClose(reason: "input overflow"))
        #expect(link.waitGone())
    }

    @Test func aStaleAppAsksForAnUpdate() throws {
        let link = try Local()
        defer { link.finish() }
        let stale = ["invalid request: unknown cmd session.upload", "the Elis on this host is too old for session.upload",
                     "unknown command 'session.upload'"]
        for (index, error) in stale.enumerated() {
            let channel = UInt32(3 + index)
            link.fixture.server.answerRaw("session.upload", #"{"ok":false,"error":"\#(error)"}"# + "\n")
            link.phone.deliver(Self.open(channel, size: 5))
            #expect(link.reader.opened(from: link.phone, channel: channel)?.error == "Update Elis on the computer to attach files")
        }
        link.fixture.server.answerRaw("session.upload", #"{"ok":false,"error":"no such session"}"# + "\n")
        link.phone.deliver(Self.open(9, size: 5))
        #expect(link.reader.opened(from: link.phone, channel: 9)?.error == "no such session")
    }

    @Test func aRemoteRowPipesToTheHost() throws {
        let harness = try Remote()
        defer { harness.finish() }
        let reply = #"{"ok":true,"result":{"upload":{"path":"/far/a.txt"}}}"#
        harness.start(size: 5, script: "cat > '\(harness.dir)/out'; printf '%s\\n' '\(reply)'")
        #expect(harness.opened() == PhoneLinkOpened())
        harness.input(Data("hel".utf8))
        harness.input(Data("lo".utf8))
        #expect(harness.closed() == PhoneLinkClose(reason: "uploaded", path: "/far/a.txt"))
        #expect(FileManager.default.contents(atPath: harness.dir + "/out") == Data("hello".utf8))
        #expect(harness.launched() == [try RemoteSession.uploadCommand(host: "h", session: "R1", name: "a.txt", size: 5)])
    }

    @Test(arguments: [
        ("exit 64", "Update Elis on h to attach files"),
        (#"printf '%s\n' '{"ok":false,"error":"invalid request: session.upload"}'; exit 1"#, "Update Elis on h to attach files"),
        ("echo 'ssh: refused' >&2; exit 255", "h gave no answer (ssh: refused)"),
        (#"exec 0<&-; touch "$0.shut"; sleep 0.3; printf '%s\n' '{"ok":false,"error":"boom"}'; exit 1"#, "boom"),
    ])
    func aRemoteFailureClosesTheChannel(script: String, reason: String) throws {
        let harness = try Remote()
        defer { harness.finish() }
        harness.start(size: 5, script: script)
        #expect(harness.opened() == PhoneLinkOpened())
        if script.contains(".shut") {
            #expect(harness.wait { FileManager.default.fileExists(atPath: harness.dir + "/script.shut") })
            harness.input(Data("hello".utf8))
        }
        #expect(harness.closed() == PhoneLinkClose(reason: reason))
    }

    @Test func stoppingARemoteUploadEndsItsProcess() throws {
        let harness = try Remote()
        defer { harness.finish() }
        harness.start(size: 5, script: "echo $$ > '\(harness.dir)/pid'; exec cat > /dev/null")
        #expect(harness.opened() == PhoneLinkOpened())
        #expect(harness.wait { (try? String(contentsOfFile: harness.dir + "/pid", encoding: .utf8))?.isEmpty == false })
        let pid = try #require(Int32((try String(contentsOfFile: harness.dir + "/pid", encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)))
        harness.stop()
        #expect(harness.wait { kill(pid, 0) != 0 })
    }

    static func open(_ channel: UInt32, name: String = "a.txt", size: Int) -> Data {
        PhoneLinkFrame.json(.open, channel: channel, PhoneLinkOpen(type: "upload", target: "S1", name: name, size: size)).encoded()
    }

    static func wait(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(30)
        while !condition() {
            if Date() > deadline { return false }
            usleep(20_000)
        }
        return true
    }

    /// A link whose app reserves `path`, with its placeholder created as the app does.
    private struct Local {
        let fixture: MobileFixture
        let phone: MemoryPhone
        let reader = FrameReader()
        let dir: String
        let path: String

        init() throws {
            (fixture, phone) = try MobileFixture.upgraded()
            dir = NSTemporaryDirectory() + "elis-upload-\(UUID().uuidString.prefix(8))"
            path = dir + "/a.txt"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: path, contents: nil)
            fixture.server.answerRaw("session.upload", #"{"ok":true,"result":{"upload":{"path":"\#(path)"}}}"# + "\n")
        }

        func close(_ channel: UInt32) -> PhoneLinkClose? {
            try? reader.next(from: phone, channel: channel, kind: .close)?.decodeJSON(PhoneLinkClose.self)
        }

        func waitAsked() -> Bool { PhoneLinkUploadTests.wait { fixture.server.requests().contains { $0.contains("session.upload") } } }

        func waitGone() -> Bool {
            PhoneLinkUploadTests.wait { ![path, path + ".part"].contains(where: FileManager.default.fileExists(atPath:)) }
        }

        func finish() {
            PhoneLinkPresenterTests.finish(fixture, phone)
            try? FileManager.default.removeItem(atPath: dir)
        }
    }

    /// One upload built directly, for a remote row whose ssh command runs `script` under `sh` instead.
    private final class Remote: @unchecked Sendable {
        let server = RawStubServer()
        let dir: String
        private let queue = DispatchQueue(label: "upload-test")
        private let lock = NSLock()
        private var frames: [PhoneLinkFrame] = []
        private var argvs: [[String]] = []
        private var upload: PhoneLinkUpload?

        init() throws {
            dir = NSTemporaryDirectory() + "elis-upload-\(UUID().uuidString.prefix(8))"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try server.start()
            server.answerRaw("session.upload", #"{"ok":true,"result":{"upload":{"host":"h","session":"R1"}}}"# + "\n")
        }

        func start(size: Int, script: String) {
            let link = PhoneLinkUpload.Link(
                frame: { [self] frame in lock.withLock { frames.append(frame) } },
                credit: { _, sent in sent() },
                ended: {})
            let upload = PhoneLinkUpload(
                channel: 3, request: PhoneLinkOpen(type: "upload", target: "S1", name: "a.txt", size: size), socketPath: server.path, queue: queue,
                link: link, command: { [self] argv in
                    lock.withLock { argvs.append(argv) }
                    return ["/bin/sh", "-c", script, dir + "/script"]
                })
            queue.sync {
                self.upload = upload
                upload.start()
            }
        }

        func input(_ bytes: Data) { queue.sync { upload?.input(bytes) } }
        func stop() { queue.sync { upload?.stop() } }
        func launched() -> [[String]] { lock.withLock { argvs } }
        func wait(_ condition: () -> Bool) -> Bool { PhoneLinkUploadTests.wait(condition) }

        func opened() -> PhoneLinkOpened? { frame(.opened).flatMap { try? $0.decodeJSON(PhoneLinkOpened.self) } }
        func closed() -> PhoneLinkClose? { frame(.close).flatMap { try? $0.decodeJSON(PhoneLinkClose.self) } }

        private func frame(_ kind: PhoneLinkKind) -> PhoneLinkFrame? {
            var found: PhoneLinkFrame?
            _ = wait {
                found = lock.withLock { frames.first { $0.kind == kind } }
                return found != nil
            }
            return found
        }

        func finish() {
            stop()
            server.stop()
            try? FileManager.default.removeItem(atPath: dir)
        }
    }
}
#endif
