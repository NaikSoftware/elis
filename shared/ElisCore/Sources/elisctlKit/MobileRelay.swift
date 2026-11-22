#if !canImport(Musl)
import Foundation
#if os(macOS)
import Network
import Security
#endif
import ElisCore

#if os(macOS)
typealias PhoneTLSIdentity = SecIdentity
#else
typealias PhoneTLSIdentity = OpenSSLIdentity
#endif

// MARK: - relay

/// The phones of every transport, and the TLS listener that produces one kind of them. Every mutable property
/// is touched on `queue` only.
final class MobileRelay: @unchecked Sendable {
    /// Connections still owing their token, on any transport; past it the oldest is dropped, so a flood cannot
    /// use up descriptors.
    private let maxUnauthenticated: Int

    var onFailure: (@Sendable () -> Void)?
    let queue = DispatchQueue(label: "elisctl.mobile")
    #if os(macOS)
    private let parameters: NWParameters
    #else
    private let identity: PhoneTLSIdentity
    #endif
    private let port: UInt16
    private let bind: String?
    let settings: PhoneSession.Settings
    private let releaseTimeout: TimeInterval
    #if os(macOS)
    private var listener: NWListener?
    #else
    private var listener: TLSPhoneListener?
    #endif
    private var phones: [ObjectIdentifier: PhoneSession] = [:]
    private var accepted = 0

    init(identity: PhoneTLSIdentity, port: UInt16, bind: String?, mobileDir: String, socketPath: String, hostName: String,
         authTimeout: TimeInterval = 10, revokeInterval: TimeInterval = 5, maxUnauthenticated: Int = 32,
         releaseTimeout: TimeInterval = 3,
         log: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data("elisctl: \($0)\n".utf8)) }) {
        #if os(macOS)
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(identity)!)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true // a phone that vanished without a FIN is dropped
        tcp.keepaliveIdle = 30
        tcp.keepaliveInterval = 10
        tcp.keepaliveCount = 3
        parameters = NWParameters(tls: tls, tcp: tcp)
        #else
        self.identity = identity
        #endif
        self.port = port
        self.bind = bind
        settings = PhoneSession.Settings(mobileDir: mobileDir, socketPath: socketPath, hostName: hostName,
                                         authTimeout: authTimeout, revokeInterval: revokeInterval, log: log)
        self.releaseTimeout = releaseTimeout
        self.maxUnauthenticated = maxUnauthenticated
    }

    #if os(macOS)
    /// Listen and return the bound port once the listener is ready; a port in use throws.
    func start() throws -> UInt16 {
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
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                failure.set(nil)
                settled.signal()
            case let .failed(error), let .waiting(error):
                if failure.set("cannot listen on \(self?.bind ?? "*"):\(self?.port ?? 0): \(error)") {
                    settled.signal()
                } else {
                    self?.settings.log("listener failed: \(error)")
                    self?.onFailure?()
                }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            accept(TLSPhoneConnection(connection, queue: queue))
        }
        queue.sync { self.listener = listener }
        listener.start(queue: queue)
        if settled.wait(timeout: .now() + 10) == .timedOut { failure.set("listener did not start") }
        if let message = failure.message {
            listener.cancel()
            throw MobileError(message)
        }
        return listener.port?.rawValue ?? port
    }
    #else
    func start() throws -> UInt16 {
        let listener = try TLSPhoneListener(identity: identity, port: port, bind: bind, queue: queue,
                                            onConnection: { [weak self] in self?.accept($0) },
                                            onFailure: { [weak self] error in
                                                self?.settings.log("listener failed: \(error)")
                                                self?.onFailure?()
                                            })
        queue.sync { self.listener = listener }
        return listener.port
    }
    #endif

    func stop() {
        queue.sync {
            #if os(macOS)
            listener?.stateUpdateHandler = nil
            #endif
            listener?.cancel()
            phones.values.forEach { $0.close() }
        }
    }

    /// Serves a phone from any transport. Call on `queue`; the connection delivers there too.
    func accept(_ connection: any PhoneTransportConnection) {
        // evicting the oldest, not refusing the newest, so a flood cannot lock a paired phone out
        let waiting = phones.values.filter { !$0.authenticated }
        if waiting.count >= maxUnauthenticated, let oldest = waiting.min(by: { $0.order < $1.order }) { oldest.close() }
        accepted += 1
        let phone = PhoneSession(connection, order: accepted, queue: queue, settings: settings) { [weak self] in
            self?.phones[ObjectIdentifier($0)] = nil
        }
        phones[ObjectIdentifier(phone)] = phone
        phone.start()
    }

    /// Authenticated phones whose connection `matches`. Call on `queue`.
    func authenticatedPhones(_ matches: (any PhoneTransportConnection) -> Bool) -> Int {
        phones.values.filter { $0.authenticated && matches($0.connection) }.count
    }

    /// Resets every grid every phone forced, waiting up to `releaseTimeout` for the app; for a relay told to stop.
    func releaseAllGrids() {
        let resets = queue.sync { phones.values.flatMap { $0.takeResets() } }
        let group = DispatchGroup()
        let socketPath = settings.socketPath
        for reset in resets {
            DispatchQueue.global().async(group: group) { _ = try? SocketClient(path: socketPath).sendRaw(reset) }
        }
        _ = group.wait(timeout: .now() + releaseTimeout)
    }

    #if os(macOS)
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
    #endif
}

#if os(macOS)
/// A TLS phone, started on the relay queue at accept so every callback lands there.
private final class TLSPhoneConnection: PhoneTransportConnection, @unchecked Sendable {
    let peerLabel: String
    var onReceive: ((Data) -> Void)?
    var onClose: (() -> Void)?
    private let connection: NWConnection

    init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        peerLabel = MobileRelay.peerAddress(connection.endpoint)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.onClose?()
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
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

    /// Records the first outcome, nil for ready; false once start has already settled.
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
#endif
#endif
