#if canImport(Glibc)
import Foundation
import Testing
@testable import elisctlKit

struct OpenSSLPhoneConnectionTests {
    private final class Accepted: @unchecked Sendable {
        private let lock = NSLock()
        private var connection: (any PhoneTransportConnection)?
        func set(_ connection: any PhoneTransportConnection) { lock.withLock { self.connection = connection } }
        func get() -> (any PhoneTransportConnection)? { lock.withLock { connection } }
    }

    @Test func aSendCompletesOnlyOnceThePhoneTookItsBytes() throws {
        let dir = try MobileFixture.privateDirectory()
        defer { try? FileManager.default.removeItem(atPath: (dir as NSString).deletingLastPathComponent) }
        try MobilePairing.ensureCertificate(in: dir)
        let (identity, _) = try MobilePairing.identity(in: dir)
        let queue = DispatchQueue(label: "test.openssl")
        let accepted = Accepted()
        let listener = try TLSPhoneListener(identity: identity, port: 0, bind: "127.0.0.1", queue: queue,
                                            onConnection: { accepted.set($0) }, onFailure: { _ in })
        defer { listener.cancel() }
        let client = try TLSLineClient(port: listener.port, reading: false)
        try #require(queue.sync { accepted.get() } != nil)
        defer { queue.sync { accepted.get()?.close() } }
        // more than loopback's socket buffers hold
        let payload = Data(repeating: 0x61, count: 32 << 20) + Data("end".utf8)
        let sent = DispatchSemaphore(value: 0)
        queue.async { accepted.get()?.send(payload) { sent.signal() } }
        #expect(sent.wait(timeout: .now() + 1) == .timedOut)
        client.startReading()
        #expect(sent.wait(timeout: .now() + 30) == .success)
        #expect(client.waitBytes(payload.count) == payload)
    }
}
#endif
