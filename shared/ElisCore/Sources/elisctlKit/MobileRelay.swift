#if !canImport(Musl)
import Foundation
import ElisCore

/// The relay's platform transports, registered by the platform's `elisctl` main before `Elisctl.main()`.
/// Unregistered, `mobile serve` cannot listen and Bluetooth is `off (unsupported)`.
public enum MobileTransports {
    nonisolated(unsafe) public static var tls: (any PhoneTLSIdentity.Type)?
    nonisolated(unsafe) public static var radio: (any BleRadio.Type)?
}

/// The certificate and key a TLS listener serves, loaded once.
public protocol PhoneTLSIdentity: AnyObject, Sendable {
    /// Whether `listen` takes `host` as its `bind`: an IP address literal.
    static func isAddress(_ host: String) -> Bool
    /// Nil when either PEM file is unusable.
    init?(certificate: String, key: String)
    /// Binds and listens, accepting on `queue`; throws with the system's reason, as NWListener does for a port in use.
    func listen(port: UInt16, bind: String?, queue: DispatchQueue,
                onConnection: @escaping @Sendable (any PhoneTransportConnection) -> Void,
                onFailure: @escaping @Sendable (String) -> Void) throws -> any PhoneTLSListener
}

public protocol PhoneTLSListener: AnyObject {
    var port: UInt16 { get }
    func cancel()
}

// MARK: - relay

/// The phones of every transport, and the TLS listener that produces one kind of them. Every mutable property
/// is touched on `queue` only.
public final class MobileRelay: @unchecked Sendable {
    /// Connections still owing their token, on any transport; past it the oldest is dropped, so a flood cannot
    /// use up descriptors.
    private let maxUnauthenticated: Int

    var onFailure: (@Sendable () -> Void)?
    public let queue = DispatchQueue(label: "elisctl.mobile")
    private let identity: any PhoneTLSIdentity
    private let port: UInt16
    private let bind: String?
    public let settings: PhoneSession.Settings
    private let releaseTimeout: TimeInterval
    private var listener: (any PhoneTLSListener)?
    private var phones: [ObjectIdentifier: PhoneSession] = [:]
    private var accepted = 0

    init(identity: any PhoneTLSIdentity, port: UInt16, bind: String?, mobileDir: String, socketPath: String, hostName: String,
         authTimeout: TimeInterval = 10, revokeInterval: TimeInterval = 5, maxUnauthenticated: Int = 32,
         releaseTimeout: TimeInterval = 3,
         log: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data("elisctl: \($0)\n".utf8)) }) {
        self.identity = identity
        self.port = port
        self.bind = bind
        settings = PhoneSession.Settings(mobileDir: mobileDir, socketPath: socketPath, hostName: hostName,
                                         authTimeout: authTimeout, revokeInterval: revokeInterval, log: log)
        self.releaseTimeout = releaseTimeout
        self.maxUnauthenticated = maxUnauthenticated
    }

    /// Listens and returns the bound port; a port in use throws.
    func start() throws -> UInt16 {
        let listener = try identity.listen(port: port, bind: bind, queue: queue,
                                           onConnection: { [weak self] in self?.accept($0) },
                                           onFailure: { [weak self] error in
                                               self?.settings.log("listener failed: \(error)")
                                               self?.onFailure?()
                                           })
        queue.sync { self.listener = listener }
        return listener.port
    }

    func stop() {
        queue.sync {
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
}
#endif
