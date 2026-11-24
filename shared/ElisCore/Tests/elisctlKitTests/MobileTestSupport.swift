#if !canImport(Musl)
#if os(macOS)
import CoreImage
import CryptoKit
import Darwin
import Network
import Security
#else
import Crypto
import Glibc
#endif
#if ELIS_PLATFORM_ADAPTERS && os(macOS)
@testable import ElisMacRelay
#elseif ELIS_PLATFORM_ADAPTERS
@testable import ElisLinuxRelay
#endif
import Foundation
import ElisCore
@testable import elisctlKit

// Fixtures shared by the relay suites; the platform packages' tests build this file too, with their transports.

#if !ELIS_PLATFORM_ADAPTERS
/// The shared suites' TLS listener, which never listens: their phones come in through `relay.accept`.
private final class StubTLSIdentity: PhoneTLSIdentity, PhoneTLSListener, @unchecked Sendable {
    let port: UInt16 = 0
    static func isAddress(_ host: String) -> Bool { true }
    init?(certificate: String, key: String) {}
    func listen(port: UInt16, bind: String?, queue: DispatchQueue,
                onConnection: @escaping @Sendable (any PhoneTransportConnection) -> Void,
                onFailure: @escaping @Sendable (String) -> Void) throws -> any PhoneTLSListener { self }
    func cancel() {}
}
#endif

final class MobileFixture: @unchecked Sendable {
    private static let transports: Void = {
        #if ELIS_PLATFORM_ADAPTERS && os(macOS)
        MacTransports.register()
        #elseif ELIS_PLATFORM_ADAPTERS
        LinuxTransports.register()
        #else
        MobileTransports.tls = StubTLSIdentity.self
        #endif
    }()

    let mobileDir: String
    let token: String
    let identity: PhoneTLSIdentity
    let fingerprint: String
    let server = RawStubServer()
    let relay: MobileRelay
    let port: UInt16
    private let lines = LogLines()

    init(maxUnauthenticated: Int = 32) throws {
        _ = Self.transports
        mobileDir = try Self.privateDirectory()
        token = try MobilePairing.loadToken(in: mobileDir)
        try MobilePairing.ensureCertificate(in: mobileDir)
        (identity, fingerprint) = try MobilePairing.identity(in: mobileDir)
        try server.start()
        let lines = lines
        relay = MobileRelay(identity: identity, port: 0, bind: "127.0.0.1", mobileDir: mobileDir, socketPath: server.path,
                            // a release bound a loaded runner cannot run out; the stub answers at once
                            hostName: "test-mac", revokeInterval: 0.3, maxUnauthenticated: maxUnauthenticated, releaseTimeout: 30,
                            log: { lines.append($0) })
        port = try relay.start()
    }

    func logged() -> [String] { lines.all() }

    func waitLogged(_ line: String) -> Bool {
        let deadline = Date().addingTimeInterval(30)
        while !logged().contains(line) {
            if Date() > deadline { return false }
            usleep(20_000)
        }
        return true
    }

    func stop() {
        relay.stop()
        server.stop()
        try? FileManager.default.removeItem(atPath: (mobileDir as NSString).deletingLastPathComponent)
    }

    static func privateDirectory() throws -> String {
        let base = NSTemporaryDirectory() + "elis-mobile-\(UUID().uuidString.prefix(8))"
        let dir = base + "/mobile"
        try MobilePairing.ensurePrivateDirectory(dir)
        return dir
    }

    #if os(macOS)
    /// Reads the matrix back through CoreImage's own QR detector, at 8 pixels a module with a 4-module quiet zone.
    static func decodeQR(_ matrix: [[Bool]]) -> String? {
        let scale = 8, side = (matrix.count + 8) * scale
        var pixels = [UInt8](repeating: 255, count: side * side)
        for (y, row) in matrix.enumerated() {
            for (x, dark) in row.enumerated() where dark {
                for dy in 0..<scale { for dx in 0..<scale { pixels[((y + 4) * scale + dy) * side + (x + 4) * scale + dx] = 0 } }
            }
        }
        let image = CIImage(bitmapData: Data(pixels), bytesPerRow: side, size: CGSize(width: side, height: side),
                            format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: nil)
        return (detector?.features(in: image).first as? CIQRCodeFeature)?.messageString
    }
    #endif

    static func mode(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]) as? Int ?? -1) & 0o777
    }
}

extension MobileFixture {
    /// A fixture and a phone that passed auth.
    static func authenticated() throws -> (MobileFixture, MemoryPhone) {
        let fixture = try MobileFixture()
        let phone = MemoryPhone(queue: fixture.relay.queue)
        fixture.relay.queue.sync { fixture.relay.accept(phone) }
        phone.deliver(#"{"auth":"\#(fixture.token)","id":1}"# + "\n")
        guard phone.readJSON()?["ok"] as? Bool == true else {
            fixture.stop()
            throw CocoaError(.fileReadUnknown)
        }
        return (fixture, phone)
    }

    /// A fixture and a phone past `{"mux":1}`.
    static func upgraded() throws -> (MobileFixture, MemoryPhone) {
        let (fixture, phone) = try authenticated()
        phone.deliver(PhoneLinkUpgrade.request)
        guard phone.readSent() == PhoneLinkUpgrade.answer else {
            fixture.stop()
            throw CocoaError(.fileReadUnknown)
        }
        return (fixture, phone)
    }
}

/// Reads the relay's frames back and joins one channel into lines.
final class MuxReader {
    private let channel: UInt32
    private var decoder = PhoneLinkDecoder()
    private var line = Data()

    init(channel: UInt32 = 0) { self.channel = channel }

    func json(from phone: MemoryPhone) -> [String: Any]? {
        line(from: phone).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }

    /// The next whole line, newline excluded.
    func line(from phone: MemoryPhone) -> Data? {
        while true {
            if let newline = line.firstIndex(of: 0x0A) {
                defer { line = Data(line[line.index(after: newline)...]) }
                return Data(line[line.startIndex..<newline])
            }
            guard let bytes = phone.readSent(), let frames = try? decoder.feed(bytes) else { return nil }
            for frame in frames where frame.kind == .data && frame.channel == channel { line.append(frame.payload) }
        }
    }
}

/// A phone connection with no transport: the test feeds bytes in on the relay queue and reads the lines sent back.
final class MemoryPhone: PhoneTransportConnection, @unchecked Sendable {
    let peerLabel = "mem:1"
    var onReceive: ((Data) -> Void)?
    var onClose: (() -> Void)?
    private let queue: DispatchQueue
    private let lock = NSLock()
    private let changed = DispatchSemaphore(value: 0)
    private var sent: [Data] = []
    private var isClosed = false
    /// Completions held back while a test plays a phone that takes no more bytes; nil while sends complete.
    private var held: [() -> Void]?

    init(queue: DispatchQueue) { self.queue = queue }

    func deliver(_ text: String) { deliver(Data(text.utf8)) }
    func deliver(_ bytes: Data) { queue.async { self.onReceive?(bytes) } }
    func peerLeft() { queue.async { self.onClose?() } }
    func closed() -> Bool { lock.withLock { isClosed } }
    /// From now on the transport makes no progress: no send completes until `release()`.
    func hold() { lock.withLock { held = [] } }
    func release() {
        let completions = lock.withLock { defer { held = nil }; return held ?? [] }
        completions.forEach(later)
    }

    /// On the relay queue, as a real transport completes; Linux's Dispatch takes only @Sendable blocks.
    private func later(_ completion: @escaping () -> Void) {
        nonisolated(unsafe) let completion = completion
        queue.async { completion() }
    }

    func send(_ data: Data, completion: @escaping () -> Void) {
        let holding = lock.withLock {
            sent.append(data)
            held?.append(completion)
            return held != nil
        }
        changed.signal()
        if !holding { later(completion) }
    }

    func close() { lock.withLock { isClosed = true } }

    func readJSON(timeout: TimeInterval = 30) -> [String: Any]? {
        readSent(timeout: timeout).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }

    /// The oldest bytes sent and not read yet, one `send` call at a time.
    func readSent(timeout: TimeInterval = 30) -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let bytes = lock.withLock({ sent.isEmpty ? nil : sent.removeFirst() }) { return bytes }
            if changed.wait(timeout: .now() + deadline.timeIntervalSinceNow) == .timedOut { return nil }
        }
    }

    func waitClosed(timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !closed() {
            if Date() > deadline { return false }
            usleep(20_000)
        }
        return true
    }
}

final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    func all() -> [String] { lock.withLock { lines } }
}

final class FingerprintBox: @unchecked Sendable { var value: String? }

/// A control socket stub that answers `version` with 9.9.9, `events.read` from a scripted ring, `session.attach`
/// with a fake viewer, and every other line with `{"echo":cmd}`, keeping the raw lines; `events.read` lines are kept
/// apart, as their cursors.
final class RawStubServer: @unchecked Sendable {
    let path = "/tmp/agm-\(UUID().uuidString.prefix(8)).sock"
    private let lock = NSLock()
    private var received: [String] = []
    private var stopped = false
    private let run = UUID().uuidString
    private var events: [String] = []
    /// Each `events.read`'s `after`, nil for the bootstrap read.
    private var eventReads: [UInt64?] = []
    private var failNextRead = false
    private var gates: [String: DispatchSemaphore] = [:]
    private var attachPick: (@Sendable ([String: Any]) -> ControlResponse?)?
    private var raw: [String: String] = [:]
    private var streamCmds: Set<String> = []
    private var streams: [StubStream] = []

    /// What `session.attach` answers; by default the fake viewer prints "hi" and echoes what it reads.
    private var attach = ControlResponse(ok: true, result: ControlResult(attach: fakeAttach("printf 'hi'; cat")))

    /// A viewer that runs `script` under `sh`, for an 80x24 pane.
    static func fakeAttach(_ script: String, paneID: String = "pane-1", screen: String = "printf '1 80 24 0 0 0\\n'",
                           remote: Bool = false, nonce: String? = nil, origin: ControlAttachOrigin? = nil) -> ControlAttach {
        ControlAttach(argv: ["/bin/sh", "-c", script], paneID: paneID, screen: ["/bin/sh", "-c", screen], remote: remote, nonce: nonce,
                      origin: origin)
    }

    /// Every `cmd` connection is answered ok and kept open as a `StubStream`, in arrival order.
    func holdStreams(_ cmd: String) { lock.withLock { streamCmds.insert(cmd) } }

    func nextStream(timeout: TimeInterval = 30) -> StubStream? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let stream = lock.withLock({ streams.isEmpty ? nil : streams.removeFirst() }) { return stream }
            if Date() > deadline { return nil }
            usleep(20_000)
        }
    }

    func answerAttach(_ response: ControlResponse) { lock.withLock { attach = response } }

    /// Answers `cmd` with `text` written as is, so a stream reply can carry lines after its ok.
    func answerRaw(_ cmd: String, _ text: String) { lock.withLock { raw[cmd] = text } }

    /// Answers each `session.attach` by its `args`; nil falls back to `answerAttach`'s answer.
    func answerAttach(by pick: @escaping @Sendable ([String: Any]) -> ControlResponse?) { lock.withLock { attachPick = pick } }

    /// `session.attach` answers only after `releaseAttach()`, or after 30 s.
    func holdAttach() { hold("session.attach") }
    func releaseAttach() { release("session.attach") }

    /// `cmd` answers only after `release(cmd)`, or after 30 s.
    func hold(_ cmd: String) { lock.withLock { gates[cmd] = DispatchSemaphore(value: 0) } }
    func release(_ cmd: String) { lock.withLock { gates.removeValue(forKey: cmd) }?.signal() }

    func requests() -> [String] { lock.withLock { received } }
    func eventReadCursors() -> [UInt64?] { lock.withLock { eventReads } }
    /// The next `events.read` answers `event run changed`, as after an app relaunch.
    func failNextEventRead() { lock.withLock { failNextRead = true } }

    /// Appends `count` `status` events with seq numbers after the last one; `padding` makes each row larger.
    func addEvents(_ count: Int, padding: Int = 0) {
        let session = String(repeating: "x", count: padding)
        lock.withLock {
            for _ in 0..<count {
                events.append(#"{"seq":\#(events.count + 1),"ts":0,"kind":"status","session":"\#(session)","payload":{}}"#)
            }
        }
    }

    /// Whether an `events.read` matching `cursor` arrives, within a slow-runner bound.
    func waitEventRead(_ cursor: (UInt64?) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(30)
        while !eventReadCursors().contains(where: cursor) {
            if Date() > deadline { return false }
            usleep(20_000)
        }
        return true
    }

    /// The ring's answer, recorded and read under one lock so a test that saw the read knows its anchor.
    private func eventsReply(_ object: [String: Any]) -> String {
        lock.withLock {
            let after = ((object["args"] as? [String: Any])?["after"] as? String).flatMap(UInt64.init)
            eventReads.append(after)
            if failNextRead {
                failNextRead = false
                return #"{"ok":false,"error":"event run changed"}"#
            }
            let start = after.map(Int.init) ?? events.count
            let items = events[min(start, events.count)..<min(start + 100, events.count)]
            return #"{"ok":true,"result":{"events":{"run":"\#(run)","next":\#(start + items.count),"items":[\#(items.joined(separator: ","))]}}}"#
        }
    }

    /// Whether `line` arrives among the requests after the first `count`, within a slow-runner bound.
    func waitFor(_ line: String, after count: Int) -> Bool {
        let deadline = Date().addingTimeInterval(30)
        while !requests().dropFirst(count).contains(line) {
            if Date() > deadline { return false }
            usleep(20_000)
        }
        return true
    }

    func start() throws {
        unlink(path)
        #if os(macOS)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            path.utf8CString.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard fd >= 0, bound == 0, listen(fd, 8) == 0 else { close(fd); throw CocoaError(.fileWriteUnknown) }
        Thread.detachNewThread { [self] in
            while true {
                let conn = accept(fd, nil, nil)
                // stop() wakes this accept with a connection of its own; the fd closes here, never under a blocked accept
                if conn < 0 || lock.withLock({ stopped }) {
                    if conn >= 0 { close(conn) }
                    close(fd)
                    return
                }
                // a client that gave up on a held answer is gone by the reply: EPIPE, not a SIGPIPE that kills the run
                #if os(macOS)
                var noSigPipe: Int32 = 1
                setsockopt(conn, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
                #endif
                if !serve(conn) { close(conn) }
            }
        }
    }

    /// Whether `conn` was handed to a `StubStream`, which then owns it.
    private func serve(_ conn: Int32) -> Bool {
        var line = Data()
        var byte: UInt8 = 0
        while read(conn, &byte, 1) == 1, byte != 0x0A { line.append(byte) }
        guard byte == 0x0A, let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return false }
        let cmd = object["cmd"] as? String ?? ""
        if cmd != "events.read" { lock.withLock { received.append(String(decoding: line, as: UTF8.self)) } }
        if lock.withLock({ streamCmds.contains(cmd) }) {
            let stream = StubStream(fd: conn, request: String(decoding: line, as: UTF8.self))
            stream.send(#"{"ok":true}"# + "\n")
            lock.withLock { streams.append(stream) }
            return true
        }
        if let gate = lock.withLock({ gates[cmd] }) { _ = gate.wait(timeout: .now() + 30) }
        if let text = lock.withLock({ raw[cmd] }) {
            let data = Data(text.utf8)
            data.withUnsafeBytes { _ = UnixSocket.write(conn, $0.baseAddress!, data.count) }
            return false
        }
        let reply = cmd == "version" ? #"{"ok":true,"result":{"app":{"version":"9.9.9"}}}"#
            : cmd == "events.read" ? eventsReply(object)
            : cmd == "session.attach" ? lock.withLock {
                let answer = attachPick?(object["args"] as? [String: Any] ?? [:]) ?? attach
                return String(decoding: (try? JSONEncoder().encode(answer)) ?? Data(), as: UTF8.self)
            }
            : #"{"ok":true,"result":{"echo":"\#(cmd)"}}"#
        let data = Data((reply + "\n").utf8)
        data.withUnsafeBytes { _ = UnixSocket.write(conn, $0.baseAddress!, data.count) }
        return false
    }

    func stop() {
        lock.withLock { stopped = true }
        if let wake = try? SocketClient(path: path).connect() { close(wake) }
        unlink(path)
    }
}

/// One held stream connection, played from the origin's side: lines both ways and the client's end.
final class StubStream: @unchecked Sendable {
    let request: String
    private let fd: Int32
    private var buffer = Data()
    private var eof = false

    init(fd: Int32, request: String) {
        self.fd = fd
        self.request = request
    }

    deinit { close(fd) }

    func send(_ text: String) { send(Data(text.utf8)) }
    func send(_ data: Data) { data.withUnsafeBytes { _ = UnixSocket.write(fd, $0.baseAddress!, data.count) } }

    /// The next line the client sent, newline excluded; nil at its end or after `timeout`.
    func readLine(timeout: TimeInterval = 30) -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                defer { buffer.removeSubrange(buffer.startIndex...newline) }
                return Data(buffer[buffer.startIndex..<newline])
            }
            guard !eof, fill(until: deadline) else { return nil }
        }
    }

    func frame(timeout: TimeInterval = 30) -> PresentationFrame? {
        readLine(timeout: timeout).flatMap { try? PresentationCodec.decode($0) }
    }

    /// The next frame `matching`, skipping others.
    func frame(timeout: TimeInterval = 30, matching: (PresentationFrame.Body) -> Bool) -> PresentationFrame? {
        let deadline = Date().addingTimeInterval(timeout)
        while let frame = frame(timeout: deadline.timeIntervalSinceNow) {
            if matching(frame.body) { return frame }
        }
        return nil
    }

    /// Whether the client ended the stream, skipping what it still sent.
    func waitEnd(timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !eof {
            buffer = Data()
            guard fill(until: deadline) || eof else { return false }
        }
        return true
    }

    /// Reads once; false on timeout.
    private func fill(until deadline: Date) -> Bool {
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let wait = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
        guard poll(&poller, 1, wait) > 0 else { return false }
        var chunk = [UInt8](repeating: 0, count: 65536)
        let count = read(fd, &chunk, chunk.count)
        if count <= 0 { eof = true } else { buffer.append(contentsOf: chunk[0..<count]) }
        return true
    }
}
#endif
