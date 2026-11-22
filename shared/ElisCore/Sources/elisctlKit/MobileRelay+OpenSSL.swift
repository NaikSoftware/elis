#if canImport(Glibc)
import CElisTLS
import Foundation
import Glibc

// The Linux half of `MobileRelay`'s TLS listener, where the Mac has NWListener: a non-blocking socket and
// non-blocking OpenSSL, every callback on the relay queue.

/// The certificate and key the listener serves, loaded once.
final class OpenSSLIdentity: @unchecked Sendable {
    let context: OpaquePointer

    init?(certificate: String, key: String) {
        guard let context = elis_tls_server_context(certificate, key) else { return nil }
        self.context = context
    }

    deinit { elis_tls_context_free(context) }
}

final class TLSPhoneListener: @unchecked Sendable {
    let port: UInt16
    private let source: DispatchSourceRead

    /// Binds and listens, accepting on `queue`; throws with the system's reason, as NWListener does for a port in use.
    init(identity: OpenSSLIdentity, port: UInt16, bind: String?, queue: DispatchQueue,
         onConnection: @escaping @Sendable (any PhoneTransportConnection) -> Void,
         onFailure: @escaping @Sendable (String) -> Void) throws {
        // OpenSSL writes the socket with write(2), and Glibc has no SO_NOSIGPIPE: a phone gone mid-write would kill the relay
        signal(SIGPIPE, SIG_IGN)
        let fd = try Self.listen(bind: bind, port: port)
        var storage = sockaddr_storage(), length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        _ = withUnsafeMutablePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        // sin_port and sin6_port sit at the same offset
        self.port = withUnsafeBytes(of: storage) { UInt16(bigEndian: $0.load(fromByteOffset: 2, as: UInt16.self)) }
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else {
                    if errno == EINTR || errno == ECONNABORTED { continue }
                    // shortcut: out of descriptors the source fires again at once; the pre-auth cap frees them soon
                    if ![EAGAIN, EWOULDBLOCK, EMFILE, ENFILE, ENOBUFS, ENOMEM].contains(errno) { onFailure(String(cString: strerror(errno))) }
                    return
                }
                // Glibc does not export accept4
                _ = fcntl(client, F_SETFD, FD_CLOEXEC)
                _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK)
                Self.keepAlive(client)
                guard let tls = elis_tls_new(identity.context, client, 1) else {
                    Glibc.close(client)
                    continue
                }
                onConnection(OpenSSLPhoneConnection(fd: client, tls: tls, queue: queue))
            }
        }
        source.setCancelHandler { Glibc.close(fd) }
        source.resume()
    }

    func cancel() { source.cancel() }

    /// The sockaddr for an IPv4 or IPv6 literal, or every interface of both families for nil; nil for anything else.
    static func socketAddress(_ host: String?, port: UInt16) -> (family: Int32, bytes: [UInt8])? {
        var v6 = sockaddr_in6()
        v6.sin6_family = sa_family_t(AF_INET6)
        v6.sin6_port = port.bigEndian
        guard let host else { return (AF_INET6, withUnsafeBytes(of: v6, Array.init)) }
        if inet_pton(AF_INET6, host, &v6.sin6_addr) == 1 { return (AF_INET6, withUnsafeBytes(of: v6, Array.init)) }
        var v4 = sockaddr_in()
        v4.sin_family = sa_family_t(AF_INET)
        v4.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &v4.sin_addr) == 1 else { return nil }
        return (AF_INET, withUnsafeBytes(of: v4, Array.init))
    }

    private static func listen(bind: String?, port: UInt16) throws -> Int32 {
        let failure = { (step: String) in MobileError("cannot listen on \(bind ?? "*"):\(port): \(step): \(String(cString: strerror(errno)))") }
        guard var address = socketAddress(bind, port: port) else { throw MobileError("--bind takes an IP address") }
        let type = Int32(SOCK_STREAM.rawValue | SOCK_NONBLOCK.rawValue | SOCK_CLOEXEC.rawValue)
        var fd = socket(address.family, type, 0)
        if fd < 0, bind == nil, errno == EAFNOSUPPORT, let any = socketAddress("0.0.0.0", port: port) {
            address = any // a host without IPv6
            fd = socket(address.family, type, 0)
        }
        guard fd >= 0 else { throw failure("socket") }
        var on: Int32 = 1, off: Int32 = 0
        let size = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, size)
        // dual-stack, as NWListener on every interface
        if bind == nil, address.family == AF_INET6 { setsockopt(fd, Int32(IPPROTO_IPV6), IPV6_V6ONLY, &off, size) }
        let bound = address.bytes.withUnsafeBytes {
            Glibc.bind(fd, $0.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t($0.count))
        }
        guard bound == 0, Glibc.listen(fd, SOMAXCONN) == 0 else {
            let error = failure(bound == 0 ? "listen" : "bind")
            Glibc.close(fd)
            throw error
        }
        return fd
    }

    /// A phone that vanished without a FIN is dropped, as the Mac's NWParameters keepalive does.
    private static func keepAlive(_ fd: Int32) {
        let size = socklen_t(MemoryLayout<Int32>.size)
        var on: Int32 = 1, idle: Int32 = 30, interval: Int32 = 10, count: Int32 = 3
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &on, size)
        setsockopt(fd, Int32(IPPROTO_TCP), TCP_KEEPIDLE, &idle, size)
        setsockopt(fd, Int32(IPPROTO_TCP), TCP_KEEPINTVL, &interval, size)
        setsockopt(fd, Int32(IPPROTO_TCP), TCP_KEEPCNT, &count, size)
    }
}

/// A TLS phone, driven like NWConnection on the relay queue: the handshake, then reads as they come and writes in
/// order. A send completes once OpenSSL has handed its last byte to the socket, or the connection ended.
final class OpenSSLPhoneConnection: PhoneTransportConnection, @unchecked Sendable {
    let peerLabel: String
    var onReceive: ((Data) -> Void)?
    var onClose: (() -> Void)?
    private let fd: Int32
    private let tls: OpaquePointer
    private let queue: DispatchQueue
    private let reads: DispatchSourceRead
    private let writes: DispatchSourceWrite
    /// `writes` is resumed: only while OpenSSL waits for the socket to take bytes, or it fires without end.
    private var writing = false
    private var handshaken = false
    private var readWantsWrite = false
    private var ended = false
    private var outbox: [(data: Data, sent: Int, completion: () -> Void)] = []

    /// Call on `queue`; the connection takes `fd` and `tls`.
    init(fd: Int32, tls: OpaquePointer, queue: DispatchQueue) {
        self.fd = fd
        self.tls = tls
        self.queue = queue
        peerLabel = Self.peerAddress(fd)
        reads = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        writes = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        // the descriptor closes only after both sources let go of it, so its number cannot come back under one
        let released = DispatchGroup()
        released.enter()
        released.enter()
        reads.setCancelHandler { released.leave() }
        writes.setCancelHandler { released.leave() }
        released.notify(queue: queue) {
            elis_tls_free(tls)
            Glibc.close(fd)
        }
        reads.setEventHandler { [weak self] in self?.pump() }
        writes.setEventHandler { [weak self] in self?.pump() }
        reads.resume()
    }

    deinit { if !ended { end() } }

    func send(_ data: Data, completion: @escaping () -> Void) {
        guard !ended else { return complete(completion) }
        outbox.append((data, 0, completion))
        if handshaken { wantWrite(flush() || readWantsWrite) }
    }

    func close() {
        guard !ended else { return }
        if handshaken { elis_tls_shutdown(tls) }
        shutdown(fd, Int32(SHUT_WR)) // the FIN follows every byte a completed send handed over
        end()
    }

    private func pump() {
        guard !ended else { return }
        if !handshaken {
            switch elis_tls_handshake(tls) {
            case 1: handshaken = true
            case ELIS_TLS_WANT_READ: return wantWrite(false)
            case ELIS_TLS_WANT_WRITE: return wantWrite(true)
            default: return fail()
            }
        }
        var buffer = [UInt8](repeating: 0, count: 65536)
        readWantsWrite = false
        reading: while !ended {
            let count = elis_tls_read(tls, &buffer, buffer.count)
            switch count {
            case 1...: onReceive?(Data(buffer[0..<count]))
            case Int(ELIS_TLS_WANT_READ): break reading
            case Int(ELIS_TLS_WANT_WRITE):
                readWantsWrite = true
                break reading
            default: return fail() // the peer's close_notify, its plain FIN, or an error
            }
        }
        guard !ended else { return }
        wantWrite(flush() || readWantsWrite)
    }

    /// Writes the outbox in order; true when OpenSSL waits for the socket to take more.
    private func flush() -> Bool {
        while !ended, let first = outbox.first {
            let count = first.data.isEmpty ? 0 : first.data.withUnsafeBytes {
                elis_tls_write(tls, $0.baseAddress! + first.sent, first.data.count - first.sent)
            }
            if count >= 0 {
                outbox[0].sent += count
                if outbox[0].sent == first.data.count { complete(outbox.removeFirst().completion) }
            } else if count == Int(ELIS_TLS_WANT_WRITE) {
                return true
            } else if count == Int(ELIS_TLS_WANT_READ) {
                return false
            } else {
                fail()
                return false
            }
        }
        return false
    }

    /// Later, on the relay queue the send came from, as NWConnection's completions run.
    private func complete(_ completion: @escaping () -> Void) {
        nonisolated(unsafe) let work = completion
        queue.async { work() }
    }

    private func wantWrite(_ wanted: Bool) {
        guard wanted != writing, !ended else { return }
        writing = wanted
        if wanted { writes.resume() } else { writes.suspend() }
    }

    private func fail() {
        let handler = onClose
        end()
        handler?()
    }

    private func end() {
        ended = true
        let pending = outbox.map(\.completion)
        outbox = []
        pending.forEach(complete)
        reads.cancel()
        writes.cancel()
        if !writing { writes.resume() } // a suspended source must not be released
        writing = true
    }

    /// The numeric address; a dual-stack listener sees IPv4 peers as `::ffff:a.b.c.d`, printed plain as on the Mac.
    private static func peerAddress(_ fd: Int32) -> String {
        var storage = sockaddr_storage(), length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let named = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getpeername(fd, $0, &length) == 0 && getnameinfo($0, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            }
        }
        guard named else { return "-" }
        let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return text.hasPrefix("::ffff:") && text.contains(".") ? String(text.dropFirst(7)) : text
    }
}
#endif
