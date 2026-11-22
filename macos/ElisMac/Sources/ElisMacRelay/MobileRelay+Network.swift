import CryptoKit
import elisctlKit
import Foundation
import Network
import Security

// The Mac half of `MobileRelay`'s TLS listener: NWListener over an in-memory identity, every callback on the
// relay queue.

/// The certificate and key the listener serves. Never touches the keychain.
final class NetworkTLSIdentity: PhoneTLSIdentity, @unchecked Sendable {
    let identity: SecIdentity

    static func isAddress(_ host: String) -> Bool { IPv4Address(host) != nil || IPv6Address(host) != nil }

    init?(certificate: String, key: String) {
        guard let keyPEM = try? String(contentsOfFile: key, encoding: .utf8),
              let certPEM = try? String(contentsOfFile: certificate, encoding: .utf8),
              let x963 = try? P256.Signing.PrivateKey(pemRepresentation: keyPEM).x963Representation else { return nil }
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        let base64 = certPEM.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let key = SecKeyCreateWithData(x963 as CFData, attributes as CFDictionary, nil),
              let der = Data(base64Encoded: base64), let cert = SecCertificateCreateWithData(nil, der as CFData),
              // an explicit-parameter cert has no key here, and SecIdentityCreate raises an uncatchable exception on it
              SecCertificateCopyKey(cert) != nil,
              let identity = SecIdentityCreate(nil, cert, key) else { return nil }
        self.identity = identity
    }

    /// Listens and returns once the listener is ready; a port in use throws.
    func listen(port: UInt16, bind: String?, queue: DispatchQueue,
                onConnection: @escaping @Sendable (any PhoneTransportConnection) -> Void,
                onFailure: @escaping @Sendable (String) -> Void) throws -> any PhoneTLSListener {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(identity)!)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true // a phone that vanished without a FIN is dropped
        tcp.keepaliveIdle = 30
        tcp.keepaliveInterval = 10
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: tls, tcp: tcp)
        let listenPort = NWEndpoint.Port(rawValue: port) ?? .any
        let listener: NWListener
        if let bind {
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(bind), port: listenPort)
            listener = try NWListener(using: parameters)
        } else {
            listener = try NWListener(using: parameters, on: listenPort)
        }
        let settled = DispatchSemaphore(value: 0)
        let failure = FailureBox()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                failure.set(nil)
                settled.signal()
            case let .failed(error), let .waiting(error):
                if failure.set("cannot listen on \(bind ?? "*"):\(port): \(error)") {
                    settled.signal()
                } else {
                    onFailure("\(error)")
                }
            default:
                break
            }
        }
        listener.newConnectionHandler = { connection in onConnection(TLSPhoneConnection(connection, queue: queue)) }
        listener.start(queue: queue)
        if settled.wait(timeout: .now() + 10) == .timedOut { failure.set("listener did not start") }
        if let message = failure.message {
            listener.cancel()
            throw MobileError(message)
        }
        return NetworkPhoneListener(listener, port: listener.port?.rawValue ?? port)
    }
}

private final class NetworkPhoneListener: PhoneTLSListener {
    let port: UInt16
    private let listener: NWListener

    init(_ listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    func cancel() {
        listener.stateUpdateHandler = nil
        listener.cancel()
    }
}

/// A TLS phone, started on the relay queue at accept so every callback lands there.
private final class TLSPhoneConnection: PhoneTransportConnection, @unchecked Sendable {
    let peerLabel: String
    var onReceive: ((Data) -> Void)?
    var onClose: (() -> Void)?
    private let connection: NWConnection

    init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        peerLabel = Self.peerAddress(connection.endpoint)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.onClose?()
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    /// A dual-stack listener reports IPv4 peers as `::ffff:a.b.c.d`; print the plain address without a scope.
    static func peerAddress(_ endpoint: NWEndpoint) -> String {
        guard case let .hostPort(host, _) = endpoint else { return "\(endpoint)" }
        let text: String
        switch host {
        case let .ipv6(address): text = address.asIPv4.map { "\($0)" } ?? "\(address)"
        default: text = "\(host)"
        }
        return String(text.prefix { $0 != "%" })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self, let onReceive else { return }
            if let data { onReceive(data) }
            if done || error != nil { onClose?() } else if self.onReceive != nil { receive() }
        }
    }

    func send(_ data: Data, completion: @escaping () -> Void) {
        connection.send(content: data, completion: .contentProcessed { _ in completion() })
    }

    func close() { connection.cancel() }
}

private final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false
    private(set) var message: String?

    /// Records the first outcome, nil for ready; false once listen has already settled.
    @discardableResult
    func set(_ message: String?) -> Bool {
        lock.withLock {
            guard !settled else { return false }
            settled = true
            self.message = message
            return true
        }
    }
}
