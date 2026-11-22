#if !canImport(Musl)
#if os(macOS)
import CoreImage
import CryptoKit
import Darwin
import Network
import Security
#else
import Glibc
#endif
import Foundation
import Testing
import ElisCore
@testable import elisctlKit

struct MobileCommandsTests {
    @Test func pairLinkEncodesEveryValueTheWayThePhoneDecodesIt() throws {
        let fingerprint = String(repeating: "ab", count: 32)
        let link = MobilePairing.pairLink(host: "192.168.1.5", port: 8765, token: "tok-en_" + String(repeating: "x", count: 30),
                                          fingerprint: fingerprint, name: "Nick's Mac+Book Pro")
        #expect(link.hasPrefix("elis://pair?h=192.168.1.5&p=8765&t="))
        #expect(!link.contains(" ") && !link.contains("'") && !link.contains("+"))
        let components = try #require(URLComponents(string: link))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(components.scheme == "elis" && components.host == "pair")
        #expect(query["n"] == "Nick's Mac+Book Pro")
        #expect(query["t"] == "tok-en_" + String(repeating: "x", count: 30))
        #expect(query["f"]?.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil)
        #expect(query["p"] == "8765")
    }

    @Test func lanAddressesPutVirtualInterfacesLast() {
        let ordered = MobilePairing.orderedLAN([("bridge100", "192.168.64.1"), ("utun3", "10.8.0.2"), ("en0", "192.168.1.5"),
                                                 ("vmnet8", "172.16.0.1"), ("en1", "192.168.1.5"), ("en7", "10.0.0.9")])
        #expect(ordered == ["192.168.1.5", "10.0.0.9", "192.168.64.1", "10.8.0.2", "172.16.0.1"])
    }

    @Test func tokenIsPrivateBase64URLAndResetReplacesIt() throws {
        let dir = try MobileFixture.privateDirectory()
        defer { try? FileManager.default.removeItem(atPath: (dir as NSString).deletingLastPathComponent) }
        let token = try MobilePairing.loadToken(in: dir)
        #expect(token.count >= 32 && token.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil)
        #expect(try MobilePairing.loadToken(in: dir) == token)
        #expect(MobileFixture.mode(dir + "/token") == 0o600)
        #expect(MobileFixture.mode(dir) == 0o700)
        let fresh = try MobilePairing.loadToken(in: dir, fresh: true)
        #expect(fresh != token && MobilePairing.currentToken(in: dir) == fresh)
        #expect(MobileFixture.mode(dir + "/token") == 0o600)
    }

    @Test func sameSecretComparesWholeValues() {
        #expect(MobilePairing.sameSecret("abc", "abc"))
        #expect(!MobilePairing.sameSecret("abc", "abd"))
        #expect(!MobilePairing.sameSecret("abc", "abcd"))
        #expect(!MobilePairing.sameSecret("", "a"))
    }

    @Test func qrHasFinderPatternsInTheThreeUprightCorners() throws {
        let matrix = try MobilePairing.qrMatrix("elis://pair?h=10.0.0.1&p=8765")
        let size = matrix.count
        #expect(size >= 21 && matrix.allSatisfy { $0.count == size })
        let finderRow = { (row: Int, from: Int) in (from..<from + 7).allSatisfy { matrix[row][$0] } }
        #expect(finderRow(0, 0) && finderRow(0, size - 7) && finderRow(size - 1, 0))
        #expect(!finderRow(size - 1, size - 7))
        #if os(macOS)
        #expect(MobileFixture.decodeQR(matrix) == "elis://pair?h=10.0.0.1&p=8765")
        #endif
        let rows = MobilePairing.qrRows(matrix)
        #expect(rows.count == (size + 4 + 1) / 2)
        #expect(rows[0].hasPrefix("\u{1b}[97;107m▀"))
    }

    @Test(arguments: ["0", "1023"])
    func servePortsBelow1024AreRefused(_ port: String) {
        var message: String?
        do { _ = try Elisctl.parseAsRoot(["mobile", "serve", "--port", port]) } catch { message = Elisctl.message(for: error) }
        #expect(message == "port must be 1024...65535")
    }

    @Test func onlyResourceErrorsCountAsTransient() {
        #expect([EMFILE, ENFILE, EINTR, EAGAIN].allSatisfy(MobilePairing.isTransient))
        #expect(![ENOENT, EACCES, ENOTDIR].contains(where: MobilePairing.isTransient))
    }

    @Test func anInMemoryPhoneAuthenticatesForwardsAndReleasesItsGridOnClose() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let phone = MemoryPhone(queue: fixture.relay.queue)
        fixture.relay.queue.sync { fixture.relay.accept(phone) }
        phone.deliver(#"{"auth":"\#(fixture.token)","id":1}"# + "\n")
        #expect(phone.readJSON()?["ok"] as? Bool == true)
        phone.deliver(#"{"cmd":"session.grid","target":"S1","args":{"columns":40,"rows":20},"id":2}"# + "\n")
        let answer = try #require(phone.readJSON())
        #expect(answer["id"] as? Int == 2 && (answer["result"] as? [String: Any])?["echo"] as? String == "session.grid")
        let before = fixture.server.requests().count
        phone.peerLeft()
        let right = #"{"args":{"pane":"right","reset":true},"cmd":"session.grid","target":"S1"}"#
        #expect(fixture.server.waitFor(right, after: before))
        #expect(fixture.logged().contains("phone disconnected from mem:1"))
        #expect(phone.closed())
    }
}

struct MobileBluetoothTests {
    @Test func pairLinkOffersBluetoothAndOmitsAMissingHost() {
        let link = MobilePairing.pairLink(host: "10.0.0.2", port: 8765, token: "T", fingerprint: "ab", name: "Mac", bluetooth: true)
        #expect(link == "elis://pair?h=10.0.0.2&p=8765&t=T&f=ab&n=Mac&b=1")
        let radioOnly = MobilePairing.pairLink(host: nil, port: 8765, token: "T", fingerprint: "ab", name: "Mac", bluetooth: true)
        #expect(radioOnly == "elis://pair?t=T&f=ab&n=Mac&b=1")
        #expect(!MobilePairing.pairLink(host: "h", port: 1, token: "T", fingerprint: "ab", name: "Mac", bluetooth: false).contains("b="))
    }

    @Test func anUnopenableLockIsNotReportedAsBusy() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        try FileManager.default.createDirectory(atPath: fixture.mobileDir + "/bluetooth.lock", withIntermediateDirectories: false)
        let lines = LogLines()
        #expect(!MobileBluetooth(relay: fixture.relay, token: fixture.token, status: { lines.append($0) }).start())
        #expect(lines.all() == ["off (unsupported)"])
        #expect(fixture.logged().contains { $0.hasPrefix("bluetooth: cannot open ") })
    }

    @Test func aHeldLockLeavesBluetoothOffForThisRelay() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let held = open(fixture.mobileDir + "/bluetooth.lock", O_RDWR | O_CREAT, 0o600)
        defer { close(held) }
        try #require(flock(held, LOCK_EX | LOCK_NB) == 0)
        let lines = LogLines()
        // never reaches CoreBluetooth: the lock is taken first
        MobileBluetooth(relay: fixture.relay, token: fixture.token, status: { lines.append($0) }).start()
        #expect(lines.all() == ["off (in use by another relay)"])
    }
}
#endif
