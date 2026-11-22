#if !canImport(Musl)
#if ELIS_PLATFORM_ADAPTERS
#if os(macOS)
import CoreImage
import CryptoKit
import Darwin
import Network
import Security
#else
import CElisTLS
import Crypto
import Glibc
#endif
import Foundation
import Testing
import ElisCore
@testable import elisctlKit
#if os(macOS)
@testable import ElisMacRelay
#else
@testable import ElisLinuxRelay
#endif

struct MobileRelayTransportTests {
    @Test func relayAuthenticatesForwardsAndTagsAnswers() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let client = try fixture.connect()
        #expect(client.peerFingerprint == fixture.fingerprint)
        client.send(#"{"auth":"\#(fixture.token)","id":1}"#)
        let hello = try #require(client.readJSON())
        #expect(hello["ok"] as? Bool == true && hello["id"] as? Int == 1)
        let result = try #require(hello["result"] as? [String: Any])
        #expect(result["host"] as? String == "test-mac" && result["version"] as? String == "9.9.9")

        client.send(#"{"cmd":"tree","id":7,"args":{"unknownArg":1}}"#)
        let answer = try #require(client.readJSON())
        #expect(answer["id"] as? Int == 7 && answer["ok"] as? Bool == true)
        #expect((answer["result"] as? [String: Any])?["echo"] as? String == "tree")
        #expect(fixture.server.requests().last == #"{"args":{"unknownArg":1},"cmd":"tree"}"#)
    }

    @Test func aPhoneCannotDriveTheRelayItself() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let client = try fixture.connect()
        client.send(#"{"auth":"\#(fixture.token)","id":1}"#)
        #expect(client.readJSON()?["ok"] as? Bool == true)
        let before = fixture.server.requests().count
        for (id, cmd) in ["phone.status", "phone.enable", "phone.revoke"].enumerated() {
            client.send(#"{"cmd":"\#(cmd)","id":\#(id + 2)}"#)
            let refusal = try #require(client.readJSON())
            #expect(refusal["ok"] as? Bool == false && refusal["id"] as? Int == id + 2)
            #expect(refusal["error"] as? String == "phone.* is not available from a phone")
        }
        client.send(#"{"cmd":"tree","id":9}"#)
        #expect(client.readJSON()?["id"] as? Int == 9)
        #expect(Array(fixture.server.requests().dropFirst(before)) == [#"{"cmd":"tree"}"#])
    }

    @Test func wrongTokenIsRefusedAndClosed() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let client = try fixture.connect()
        client.send(#"{"auth":"\#(String(repeating: "z", count: 43))","id":3}"#)
        let refusal = try #require(client.readJSON())
        #expect(refusal["ok"] as? Bool == false && refusal["id"] as? Int == 3 && refusal["error"] as? String == "unauthorized")
        #expect(client.waitClosed())
        #expect(fixture.logged().contains { $0.hasPrefix("refused ") && $0.hasSuffix(": wrong token") })
        #expect(!fixture.logged().contains { $0.hasPrefix("phone disconnected") })
    }

    @Test func preAuthGarbageClosesTheConnection() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let client = try fixture.connect()
        client.send(String(repeating: "g", count: 5000), newline: false)
        #expect(client.waitClosed())
        #expect(client.readJSON(timeout: 0.1) == nil)
    }

    @Test func resettingTheTokenDropsAnIdlePhone() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let client = try fixture.connect()
        client.send(#"{"auth":"\#(fixture.token)","id":1}"#)
        #expect(client.readJSON()?["ok"] as? Bool == true)
        _ = try MobilePairing.loadToken(in: fixture.mobileDir, fresh: true)
        #expect(client.waitClosed())
    }

    @Test func aDisconnectingPhoneGivesBackTheGridsItForced() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let client = try fixture.connect()
        client.send(#"{"auth":"\#(fixture.token)","id":1}"#)
        #expect(client.readJSON()?["ok"] as? Bool == true)
        client.send(#"{"cmd":"session.grid","target":"S1","args":{"pane":"right","columns":40,"rows":20},"id":2}"#)
        client.send(#"{"cmd":"session.grid","target":"S2","args":{"columns":40,"rows":20},"id":3}"#)
        client.send(#"{"cmd":"session.grid","target":"S2","args":{"reset":true},"id":4}"#)
        client.send(#"{"cmd":"session.grid","target":"active","args":{"columns":40,"rows":20},"id":5}"#)
        client.send(#"{"cmd":"session.grid","args":{"columns":40,"rows":20},"id":6}"#)
        let answers = (0..<5).compactMap { _ in client.readJSON()?["id"] as? Int }
        #expect(answers == [2, 3, 4, 5, 6])
        let before = fixture.server.requests().count
        client.close()
        let resets = [#"{"args":{"pane":"left","reset":true},"cmd":"session.grid","target":"S1"}"#,
                      #"{"args":{"pane":"right","reset":true},"cmd":"session.grid","target":"S1"}"#]
        #expect(fixture.server.waitFor(resets[1], after: before))
        let sentinel = #"{"cmd":"sentinel"}"#
        _ = try SocketClient(path: fixture.server.path).sendRaw(Data(sentinel.utf8))
        #expect(Array(fixture.server.requests().dropFirst(before)) == resets + [sentinel])
    }

    @Test func anAuthenticatedPhoneLeavingIsLoggedOnce() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let client = try fixture.connect()
        client.send(#"{"auth":"\#(fixture.token)","id":1}"#)
        #expect(client.readJSON()?["ok"] as? Bool == true)
        client.close()
        let deadline = Date().addingTimeInterval(30)
        while !fixture.logged().contains(where: { $0.hasPrefix("phone disconnected from ") }), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        Thread.sleep(forTimeInterval: 0.2)
        #expect(fixture.logged().filter { $0.hasPrefix("phone disconnected from ") }.count == 1)
    }

    @Test func aStoppingRelayGivesBackItsPhonesGrids() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let client = try fixture.connect()
        client.send(#"{"auth":"\#(fixture.token)","id":1}"#)
        #expect(client.readJSON()?["ok"] as? Bool == true)
        client.send(#"{"cmd":"session.grid","target":"S1","args":{"columns":40,"rows":20},"id":2}"#)
        #expect(client.readJSON()?["ok"] as? Bool == true)
        let before = fixture.server.requests().count
        fixture.relay.releaseAllGrids()
        #expect(Array(fixture.server.requests().dropFirst(before)).sorted() == [#"{"args":{"pane":"left","reset":true},"cmd":"session.grid","target":"S1"}"#,
                                                                               #"{"args":{"pane":"right","reset":true},"cmd":"session.grid","target":"S1"}"#])
    }

    @Test(arguments: ["delete", "unreadable", "short"])
    func aMissingOrInvalidTokenDropsAPairedPhone(_ change: String) throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let client = try fixture.connect()
        client.send(#"{"auth":"\#(fixture.token)","id":1}"#)
        #expect(client.readJSON()?["ok"] as? Bool == true)
        let path = fixture.mobileDir + "/token"
        switch change {
        case "delete": unlink(path)
        case "unreadable": chmod(path, 0)
        default: try Data("short\n".utf8).write(to: URL(fileURLWithPath: path))
        }
        #expect(client.waitClosed())
    }

    @Test func aFullPreAuthCapEvictsTheOldestConnection() throws {
        let fixture = try MobileFixture(maxUnauthenticated: 1)
        defer { fixture.stop() }
        let stale = try fixture.connect()
        let phone = try fixture.connect()
        #expect(stale.waitClosed())
        phone.send(#"{"auth":"\#(fixture.token)","id":1}"#)
        #expect(phone.readJSON()?["ok"] as? Bool == true)
    }

    // a separate process: serve ends by exit
    @Test func serveExitsWhenThePairingIsResetUnderIt() throws {
        let dir = try MobileFixture.privateDirectory()
        defer { try? FileManager.default.removeItem(atPath: (dir as NSString).deletingLastPathComponent) }
        let server = RawStubServer()
        try server.start()
        defer { server.stop() }
        // the products directory holds the test bundle and the built elisctl
        #if os(macOS)
        let tool = Bundle(for: MobileFixture.self).bundleURL.deletingLastPathComponent().appendingPathComponent("elisctl-mac")
        #else
        let tool = Bundle.main.bundleURL.appendingPathComponent("elisctl-linux") // the test executable's own directory
        #endif
        try #require(FileManager.default.isExecutableFile(atPath: tool.path), "\(tool.path)")
        var process = Process(), printed = LogLines(), err = Pipe()
        // below the ephemeral range the in-process fixtures bind through port 0; a taken port gets another try
        for _ in 0..<3 {
            process = Process()
            printed = LogLines()
            err = Pipe()
            process.executableURL = tool
            process.arguments = ["mobile", "serve", "--port", String(Int.random(in: 20000...32767)), "--bind", "127.0.0.1", "--no-qr",
                                 "--no-bluetooth", "--socket", server.path]
            process.environment = ProcessInfo.processInfo.environment.merging(
                ["ELIS_STATE_DIR": (dir as NSString).deletingLastPathComponent]) { $1 }
            let out = Pipe(), lines = printed
            process.standardOutput = out
            process.standardError = err
            out.fileHandleForReading.readabilityHandler = { lines.append(String(decoding: $0.availableData, as: UTF8.self)) }
            try process.run()
            let listening = Date().addingTimeInterval(30)
            while !printed.all().joined().contains("Listening on"), process.isRunning, Date() < listening { usleep(20_000) }
            if process.isRunning { break }
            out.fileHandleForReading.readabilityHandler = nil
            let failure = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            guard failure.contains("Address already in use") else { break }
        }
        let served = process
        defer { if served.isRunning { kill(served.processIdentifier, SIGKILL); served.waitUntilExit() } }
        try #require(process.isRunning)

        _ = try MobilePairing.loadToken(in: dir, fresh: true)

        let exited = Date().addingTimeInterval(30)
        while process.isRunning, Date() < exited { usleep(20_000) }
        try #require(!process.isRunning)
        #expect(process.terminationStatus == 1)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(stderr.contains("elisctl: \(PhoneRelayLine.pairingReset)\n"))
        #expect(stderr.contains("elisctl: bluetooth: off (disabled)\n"))
        #expect(!printed.all().joined().contains("b=1"))
    }

    @Test func secondRelayOnTheSamePortFails() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let other = MobileRelay(identity: fixture.identity, port: fixture.port, bind: nil, mobileDir: fixture.mobileDir,
                                socketPath: fixture.server.path, hostName: "test-mac")
        #expect(throws: (any Error).self) { try other.start() }
        other.stop()
    }
}

struct MobileBluetoothTransportTests {
    @Test func aPairedPhoneHandshakesForwardsAndGivesBackItsGrid() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let phone = try BlePhone(fixture)
        try phone.handshake(token: fixture.token)
        phone.send(#"{"auth":"\#(fixture.token)","id":1}"#)
        #expect(phone.readJSON()?["ok"] as? Bool == true)
        phone.send(#"{"cmd":"session.grid","target":"S1","args":{"columns":40,"rows":20},"id":2}"#)
        #expect(phone.readJSON()?["id"] as? Int == 2)
        let before = fixture.server.requests().count
        phone.close()
        let right = #"{"args":{"pane":"right","reset":true},"cmd":"session.grid","target":"S1"}"#
        #expect(fixture.server.waitFor(right, after: before))
        let label = "bt:" + phone.message1.prefix(2).map { String(format: "%02x", $0) }.joined()
        #expect(fixture.logged().contains("phone connected from \(label)"))
        #expect(fixture.waitLogged("phone disconnected from \(label)"))
    }

    @Test func aWrongKeyGetsTheRejectFrameBeforeTheClose() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let phone = try BlePhone(fixture)
        try phone.sendMessage1(token: String(repeating: "z", count: 43))
        #expect(phone.readFrame() == Data([0x01]))
        #expect(phone.waitClosed())
    }

    @Test func aPhoneOverTheCapGetsBusy() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let radio = MobileBluetooth(relay: fixture.relay, token: fixture.token, maxPhones: 1, status: { _ in })
        let first = try BlePhone(fixture, radio)
        try first.handshake(token: fixture.token)
        first.send(#"{"auth":"\#(fixture.token)","id":1}"#)
        #expect(first.readJSON()?["ok"] as? Bool == true)
        let second = try BlePhone(fixture, radio)
        try second.sendMessage1(token: fixture.token)
        #expect(second.readFrame() == Data([0x02]))
        #expect(second.waitClosed())
    }

    @Test func theUnauthorizedAnswerArrivesBeforeTheClose() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let phone = try BlePhone(fixture)
        try phone.handshake(token: fixture.token)
        phone.send(#"{"auth":"\#(String(repeating: "z", count: 43))","id":3}"#)
        #expect(phone.readJSON()?["error"] as? String == "unauthorized")
        #expect(phone.waitClosed())
    }

    @Test func aLongLineCrossesFramesIntactBothWays() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let phone = try BlePhone(fixture)
        try phone.handshake(token: fixture.token)
        phone.send(#"{"auth":"\#(fixture.token)","id":1}"#)
        #expect(phone.readJSON()?["ok"] as? Bool == true)
        // random letters barely deflate, so the answer outruns the socket buffer
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let cmd = String((0..<20000).map { _ in alphabet.randomElement() ?? "a" })
        phone.send(#"{"cmd":"\#(cmd)","id":2}"#)
        let answer = try #require(phone.readJSON())
        #expect((answer["result"] as? [String: Any])?["echo"] as? String == cmd)
        #expect(phone.framesOpened > 5)
    }

    @Test func aTamperedFrameClosesWithoutForwarding() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let phone = try BlePhone(fixture)
        try phone.handshake(token: fixture.token)
        phone.send(#"{"auth":"\#(fixture.token)","id":1}"#)
        #expect(phone.readJSON()?["ok"] as? Bool == true)
        let before = fixture.server.requests().count
        var frame = try phone.seal(#"{"cmd":"tree","id":2}"# + "\n")
        frame[frame.count - 1] ^= 0x01
        phone.write(BleFramer.frame(frame))
        #expect(phone.waitClosed())
        #expect(fixture.server.requests().count == before)
    }

    @Test func replayedHandshakesDoNotHoldTheCapFromAPairedPhone() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let radio = MobileBluetooth(relay: fixture.relay, token: fixture.token, maxPhones: 1, status: { _ in })
        let sniffed = try BlePhone(fixture, radio)
        try sniffed.handshake(token: fixture.token)
        let replay = try BlePhone(fixture, radio)
        replay.write(BleFramer.frame(sniffed.message1))
        #expect(replay.readFrame()?.count == 48)
        let paired = try BlePhone(fixture, radio)
        try paired.handshake(token: fixture.token)
        paired.send(#"{"auth":"\#(fixture.token)","id":1}"#)
        #expect(paired.readJSON()?["ok"] as? Bool == true)
        let late = try BlePhone(fixture, radio)
        try late.sendMessage1(token: fixture.token)
        #expect(late.readFrame() == Data([0x02]))
    }

    #if os(macOS)
    @Test func outputDrainsWhenTheStreamStopsReportingSpace() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let phone = try BlePhone(fixture, output: FakeOutput())
        try phone.handshake(token: fixture.token)
        phone.send(#"{"auth":"\#(fixture.token)","id":1}"#)
        #expect(phone.readJSON()?["ok"] as? Bool == true)
    }
    #endif

    @Test func aPhoneThatStopsReadingIsDropped() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let radio = MobileBluetooth(relay: fixture.relay, token: fixture.token, limits: .init(maxPending: 64 << 10), status: { _ in })
        let phone = try BlePhone(fixture, radio)
        try phone.handshake(token: fixture.token)
        phone.send(#"{"auth":"\#(fixture.token)","id":1}"#)
        #expect(phone.readJSON()?["ok"] as? Bool == true)
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        for id in 2..<14 {
            let cmd = String((0..<20000).map { _ in alphabet.randomElement() ?? "a" })
            phone.send(#"{"cmd":"\#(cmd)","id":\#(id)}"#)
        }
        #expect(fixture.waitLogged("phone disconnected from \(phone.label)"))
    }

    @Test func poweringOffDropsBluetoothPhonesAndTheirGrids() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let lines = LogLines()
        let radio = MobileBluetooth(relay: fixture.relay, token: fixture.token, status: { lines.append($0) })
        let phone = try BlePhone(fixture, radio)
        try phone.handshake(token: fixture.token)
        phone.send(#"{"auth":"\#(fixture.token)","id":1}"#)
        #expect(phone.readJSON()?["ok"] as? Bool == true)
        phone.send(#"{"cmd":"session.grid","target":"S1","args":{"columns":40,"rows":20},"id":2}"#)
        #expect(phone.readJSON()?["id"] as? Int == 2)
        let before = fixture.server.requests().count
        fixture.relay.queue.sync { radio.off("powered off") }
        #expect(phone.waitClosed())
        #expect(fixture.server.waitFor(#"{"args":{"pane":"right","reset":true},"cmd":"session.grid","target":"S1"}"#, after: before))
        #expect(lines.all() == ["off (powered off)"])
    }

    @Test func aFailedRotationKeepsOpenPhones() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let lines = LogLines()
        let radio = MobileBluetooth(relay: fixture.relay, token: fixture.token, status: { lines.append($0) })
        let phone = try BlePhone(fixture, radio)
        try phone.handshake(token: fixture.token)
        phone.send(#"{"auth":"\#(fixture.token)","id":1}"#)
        #expect(phone.readJSON()?["ok"] as? Bool == true)
        fixture.relay.queue.sync { radio.advertisingFailed("service", CocoaError(.featureUnsupported)) }
        phone.send(#"{"cmd":"tree","id":2}"#)
        #expect(phone.readJSON()?["id"] as? Int == 2)
        #expect(lines.all() == ["off (unsupported)"])
        #expect(fixture.logged().contains { $0.hasPrefix("bluetooth service failed: ") })
    }

    #if os(Linux)
    @Test func aCloseStopsWaitingForAPhoneThatStopsReading() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let radio = MobileBluetooth(relay: fixture.relay, token: fixture.token, limits: .init(flushTimeout: 0.3), status: { _ in })
        let phone = try BlePhone(fixture, radio)
        try phone.handshake(token: fixture.token)
        phone.send(#"{"auth":"\#(fixture.token)","id":1}"#)
        #expect(phone.readJSON()?["ok"] as? Bool == true)
        let before = fixture.server.requests().count
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        for id in 2..<5 {
            let cmd = String((0..<20000).map { _ in alphabet.randomElement() ?? "a" })
            phone.send(#"{"cmd":"\#(cmd)","id":\#(id)}"#)
        }
        let deadline = Date().addingTimeInterval(30)
        while fixture.server.requests().count < before + 3, Date() < deadline { usleep(20_000) }
        usleep(300_000) // the unread answers back up behind the small socket buffer
        try #require(!phone.peerClosed())
        fixture.relay.queue.sync { radio.off("powered off") }
        let closing = Date().addingTimeInterval(10)
        while !phone.peerClosed(), Date() < closing { usleep(20_000) }
        #expect(phone.peerClosed())
    }
    #else
    @Test func aCloseStopsWaitingForAPhoneThatStopsReading() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let radio = MobileBluetooth(relay: fixture.relay, token: fixture.token, limits: .init(flushTimeout: 0.3), status: { _ in })
        let output = FakeOutput()
        let phone = try BlePhone(fixture, radio, output: output)
        try phone.handshake(token: fixture.token)
        output.stall()
        phone.send(#"{"auth":"\#(fixture.token)","id":1}"#)
        try #require(fixture.waitLogged("phone connected from \(phone.label)"))
        fixture.relay.queue.sync { radio.off("powered off") }
        #expect(output.waitClosed())
    }
    #endif
}

extension MobileFixture {
    func connect() throws -> TLSLineClient { try TLSLineClient(port: port) }
}

#if os(macOS)
/// A blocking line client over TLS that trusts any certificate and records the one it saw.
final class TLSLineClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "mobile.test.client")
    private let lock = NSLock()
    private let changed = DispatchSemaphore(value: 0)
    private var buffer = Data()
    private var closed = false
    private(set) var peerFingerprint: String?

    init(port: UInt16) throws {
        let tls = NWProtocolTLS.Options()
        let fingerprintBox = FingerprintBox()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let chain = SecTrustCopyCertificateChain(sec_trust_copy_ref(trust).takeRetainedValue()) as? [SecCertificate]
            if let leaf = chain?.first {
                fingerprintBox.value = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
            }
            complete(true)
        }, queue)
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!,
                                  using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
        let ready = DispatchSemaphore(value: 0)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: ready.signal()
            case .failed, .cancelled, .waiting: self?.markClosed(); ready.signal()
            default: break
            }
        }
        connection.start(queue: queue)
        guard ready.wait(timeout: .now() + 30) == .success, connection.state == .ready else {
            connection.cancel()
            throw CocoaError(.fileReadUnknown)
        }
        peerFingerprint = fingerprintBox.value
        receive()
    }

    deinit { connection.cancel() }

    func close() { connection.cancel() }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            lock.withLock { if let data { buffer.append(data) } }
            changed.signal()
            if done || error != nil { markClosed() } else { receive() }
        }
    }

    private func markClosed() {
        lock.withLock { closed = true }
        changed.signal()
    }

    func send(_ text: String, newline: Bool = true) {
        connection.send(content: Data((newline ? text + "\n" : text).utf8), completion: .idempotent)
    }

    func readJSON(timeout: TimeInterval = 30) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let line: Data? = lock.withLock {
                guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[buffer.index(after: newline)...])
                return Data(line)
            }
            if let line { return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] }
            if lock.withLock({ closed }) || changed.wait(timeout: .now() + deadline.timeIntervalSinceNow) == .timedOut { return nil }
        }
    }

    func waitClosed(timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !lock.withLock({ closed }) {
            if changed.wait(timeout: .now() + deadline.timeIntervalSinceNow) == .timedOut { return false }
        }
        return true
    }
}
#else
/// A blocking line client over TLS that trusts any certificate and records the one it saw.
final class TLSLineClient: @unchecked Sendable {
    private let fd: Int32
    private let context: OpaquePointer
    private let tls: OpaquePointer
    /// OpenSSL takes one call at a time on a connection; reads poll outside it.
    private let io = NSLock()
    private let lock = NSLock()
    private let changed = DispatchSemaphore(value: 0)
    private var buffer = Data()
    private var closed = false
    private(set) var peerFingerprint: String?

    /// `reading: false` leaves every byte in the socket until `startReading()`.
    init(port: UInt16, reading: Bool = true) throws {
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        self.fd = fd
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Glibc.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        guard connected == 0, let context = elis_tls_client_context() else {
            Glibc.close(fd)
            throw CocoaError(.fileReadUnknown)
        }
        self.context = context
        guard let tls = elis_tls_new(context, fd, 0) else {
            elis_tls_context_free(context)
            Glibc.close(fd)
            throw CocoaError(.fileReadUnknown)
        }
        self.tls = tls
        let deadline = Date().addingTimeInterval(30)
        while true {
            let step = elis_tls_handshake(tls)
            if step == 1 { break }
            guard step != ELIS_TLS_FAILED, Date() < deadline else { throw CocoaError(.fileReadUnknown) }
            wait(for: step == ELIS_TLS_WANT_WRITE ? POLLOUT : POLLIN)
        }
        var der = [UInt8](repeating: 0, count: 16384)
        let length = elis_tls_peer_certificate(tls, &der, der.count)
        if length > 0, length <= der.count {
            peerFingerprint = SHA256.hash(data: der[0..<length]).map { String(format: "%02x", $0) }.joined()
        }
        if reading { startReading() }
    }

    func startReading() {
        Thread { [weak self] in
            while let self, self.readOnce() {}
        }.start()
    }

    /// The first `count` bytes, or nil once closed or past the timeout.
    func waitBytes(_ count: Int, timeout: TimeInterval = 30) -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let bytes: Data = lock.withLock({ buffer.count >= count ? Data(buffer.prefix(count)) : nil }) { return bytes }
            if lock.withLock({ closed }) || changed.wait(timeout: .now() + deadline.timeIntervalSinceNow) == .timedOut { return nil }
        }
    }

    deinit {
        elis_tls_free(tls)
        elis_tls_context_free(context)
        Glibc.close(fd)
    }

    func close() {
        io.withLock { elis_tls_shutdown(tls) }
        Glibc.shutdown(fd, Int32(SHUT_RDWR))
        markClosed()
    }

    private func wait(for events: Int32) {
        var poller = pollfd(fd: fd, events: Int16(events), revents: 0)
        _ = poll(&poller, 1, 50)
    }

    private func readOnce() -> Bool {
        if lock.withLock({ closed }) { return false }
        var chunk = [UInt8](repeating: 0, count: 65536)
        let count = io.withLock { elis_tls_read(tls, &chunk, chunk.count) }
        if count > 0 {
            lock.withLock { buffer.append(contentsOf: chunk[0..<count]) }
            changed.signal()
        } else if count == Int(ELIS_TLS_WANT_READ) || count == Int(ELIS_TLS_WANT_WRITE) {
            wait(for: POLLIN)
        } else {
            markClosed()
            return false
        }
        return true
    }

    private func markClosed() {
        lock.withLock { closed = true }
        changed.signal()
    }

    func send(_ text: String, newline: Bool = true) {
        let bytes = Array((newline ? text + "\n" : text).utf8)
        var sent = 0
        while sent < bytes.count, !lock.withLock({ closed }) {
            let count = bytes.withUnsafeBytes { raw in io.withLock { elis_tls_write(tls, raw.baseAddress! + sent, bytes.count - sent) } }
            if count > 0 {
                sent += count
            } else if count == Int(ELIS_TLS_WANT_WRITE) || count == Int(ELIS_TLS_WANT_READ) {
                wait(for: POLLOUT)
            } else {
                return
            }
        }
    }

    func readJSON(timeout: TimeInterval = 30) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let line: Data? = lock.withLock {
                guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[buffer.index(after: newline)...])
                return Data(line)
            }
            if let line { return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] }
            if lock.withLock({ closed }) || changed.wait(timeout: .now() + deadline.timeIntervalSinceNow) == .timedOut { return nil }
        }
    }

    func waitClosed(timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !lock.withLock({ closed }) {
            if changed.wait(timeout: .now() + deadline.timeIntervalSinceNow) == .timedOut { return false }
        }
        return true
    }
}
#endif

// MARK: - fixtures

/// The phone's end of an L2CAP channel: a socket pair whose other end the relay reads as streams on the Mac, and as
/// an L2CAP socket's SDUs on Linux.
private final class BlePhone: @unchecked Sendable {
    private(set) var message1 = Data()
    private(set) var framesOpened = 0
    private let fd: Int32
    private var framer = BleFramer()
    private var frames: [Data] = []
    private var keys: BleTransportKeys?
    private var lines = Data()
    private var closed = false
    private let radio: MobileBluetooth

    #if os(Linux)
    init(_ fixture: MobileFixture, _ radio: MobileBluetooth? = nil) throws {
        let radio = radio ?? MobileBluetooth(relay: fixture.relay, token: fixture.token, status: { _ in })
        self.radio = radio
        var fds: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, Int32(SOCK_SEQPACKET.rawValue), 0, &fds) == 0)
        fd = fds[1]
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        // a small buffer, so output a phone does not read backs up in the relay as on a real channel
        var buffer: Int32 = 16384
        setsockopt(fds[0], SOL_SOCKET, SO_SNDBUF, &buffer, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fds[0], F_SETFL, fcntl(fds[0], F_GETFL) | O_NONBLOCK)
        // SDUs shorter than a frame, so frames cross SDUs
        fixture.relay.queue.sync { radio.accept(socket: fds[0], mtu: 1000) }
    }

    /// True once the relay has closed its end, read or not.
    func peerClosed() -> Bool {
        var entry = pollfd(fd: fd, events: 0, revents: 0)
        return poll(&entry, 1, 0) == 1 && entry.revents & Int16(POLLHUP) != 0
    }
    #else
    private let fake: FakeOutput?

    /// With `output`, the relay writes into that fake instead of the socket.
    init(_ fixture: MobileFixture, _ radio: MobileBluetooth? = nil, output: FakeOutput? = nil) throws {
        let radio = radio ?? MobileBluetooth(relay: fixture.relay, token: fixture.token, status: { _ in })
        self.radio = radio
        fake = output
        var fds: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        fd = fds[1]
        var on: Int32 = 1
        for end in fds { setsockopt(end, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) }
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var input: Unmanaged<CFReadStream>?, output: Unmanaged<CFWriteStream>?
        CFStreamCreatePairWithSocket(nil, fds[0], &input, &output)
        let read = try #require(input).takeRetainedValue(), write = try #require(output).takeRetainedValue()
        CFReadStreamSetProperty(read, CFStreamPropertyKey(kCFStreamPropertyShouldCloseNativeSocket), kCFBooleanTrue)
        fixture.relay.queue.sync { radio.accept(input: read as InputStream, output: fake ?? write as OutputStream, holding: nil) }
    }
    #endif

    var label: String { "bt:" + message1.prefix(2).map { String(format: "%02x", $0) }.joined() }

    func sendMessage1(token: String) throws {
        var initiator = BleInitiator(psk: BleIDs.psk(token: token))
        message1 = try initiator.start()
        write(BleFramer.frame(message1))
    }

    func handshake(token: String) throws {
        var initiator = BleInitiator(psk: BleIDs.psk(token: token))
        message1 = try initiator.start()
        write(BleFramer.frame(message1))
        keys = try initiator.finish(try #require(readFrame()))
    }

    func seal(_ text: String) throws -> Data {
        var sealing = try #require(keys)
        defer { keys = sealing }
        return try sealing.seal(Data(text.utf8))
    }

    func send(_ text: String) {
        let data = Data((text + "\n").utf8)
        for start in stride(from: 0, to: data.count, by: BleTransportKeys.maxChunk) {
            let sealed = try? keys?.seal(data.subdata(in: start..<min(start + BleTransportKeys.maxChunk, data.count)))
            write(BleFramer.frame(sealed ?? Data()))
        }
    }

    func write(_ data: Data) {
        _ = StreamBridge.writeAll(fd, data)
    }

    /// The next frame body, or nil at end of stream or after the read timeout.
    func readFrame() -> Data? {
        var bytes = [UInt8](repeating: 0, count: 4096)
        while frames.isEmpty {
            #if os(macOS)
            if let fake {
                guard let data = fake.next() else { return nil }
                frames += framer.push(data)
                continue
            }
            #endif
            let count = read(fd, &bytes, bytes.count)
            guard count > 0 else { return nil }
            frames += framer.push(Data(bytes[..<count]))
        }
        return frames.removeFirst()
    }

    func readJSON() -> [String: Any]? {
        while true {
            if let newline = lines.firstIndex(of: 0x0A) {
                let line = Data(lines[lines.startIndex..<newline])
                lines = Data(lines[(newline + 1)...])
                return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
            }
            guard let frame = readFrame(), let plain = try? keys?.open(frame) else { return nil }
            framesOpened += 1
            lines.append(plain)
        }
    }

    /// True once the relay closed its end; a frame still unread counts against it.
    func waitClosed() -> Bool {
        var byte: UInt8 = 0
        return frames.isEmpty && read(fd, &byte, 1) == 0
    }

    func close() {
        guard !closed else { return }
        closed = true
        #if os(macOS)
        Darwin.close(fd)
        #else
        Glibc.close(fd)
        #endif
    }

    deinit { close() }
}

#if os(macOS)
/// An output stream that never reports events, so only the relay's own retries move bytes: it takes `chunk` bytes
/// per write and reports no space right after one, and none at all once stalled.
private final class FakeOutput: OutputStream, @unchecked Sendable {
    private let lock = NSLock()
    private let changed = DispatchSemaphore(value: 0)
    private let chunk: Int
    private var written = Data()
    private var taken = 0
    private var justWrote = false
    private var stalled = false
    private var isClosed = false
    private weak var watcher: (any StreamDelegate)?

    init(chunk: Int = 8) {
        self.chunk = chunk
        super.init(toMemory: ())
    }

    override var delegate: (any StreamDelegate)? {
        get { watcher }
        set { watcher = newValue }
    }

    override func open() {}
    override func schedule(in aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {}
    override func remove(from aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {}
    override var streamStatus: Stream.Status { lock.withLock { isClosed ? .closed : .open } }

    override var hasSpaceAvailable: Bool {
        lock.withLock {
            defer { justWrote = false }
            return !stalled && !justWrote && !isClosed
        }
    }

    override func write(_ buffer: UnsafePointer<UInt8>, maxLength len: Int) -> Int {
        let count = lock.withLock {
            let count = min(len, chunk)
            written.append(buffer, count: count)
            justWrote = true
            return count
        }
        changed.signal()
        return count
    }

    override func close() {
        lock.withLock { isClosed = true }
        changed.signal()
    }

    func stall() { lock.withLock { stalled = true } }
    func closed() -> Bool { lock.withLock { isClosed } }

    /// Bytes written since the last call; nil once closed with nothing new, or after 30 s.
    func next() -> Data? {
        let deadline = Date().addingTimeInterval(30)
        while true {
            let (data, done): (Data, Bool) = lock.withLock {
                defer { taken = written.count }
                return (written.subdata(in: taken..<written.count), isClosed)
            }
            if !data.isEmpty { return data }
            if done || changed.wait(timeout: .now() + deadline.timeIntervalSinceNow) == .timedOut { return nil }
        }
    }

    func waitClosed() -> Bool {
        let deadline = Date().addingTimeInterval(30)
        while !closed() {
            if Date() > deadline { return false }
            usleep(20_000)
        }
        return true
    }
}
#endif
#endif
#endif
