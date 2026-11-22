#if canImport(Glibc)
import CElisBlueZ
import Foundation
import Glibc

extension MobileBluetooth {
    func makeRadio() -> any BleRadio { BlueZRadio(owner: self, queue: relay.queue) }

    /// Serves one accepted L2CAP channel, whose SDUs are at most `mtu` bytes. Call on `relay.queue`.
    func accept(socket fd: Int32, mtu: Int) {
        accept(SocketPipe(fd: fd, mtu: mtu, queue: relay.queue, limits: limits))
    }
}

/// Linux's peripheral: BlueZ over D-Bus for the advertisement and the PSM characteristic, an LE L2CAP socket for
/// the channels. Everything runs on `queue`, the bus included.
private final class BlueZRadio: BleRadio, @unchecked Sendable {
    private weak var owner: MobileBluetooth?
    private let queue: DispatchQueue
    private var bluez: OpaquePointer?
    private var sources: [any DispatchSourceProtocol] = []
    private var listener: (any DispatchSourceRead)?

    init(owner: MobileBluetooth, queue: DispatchQueue) {
        self.owner = owner
        self.queue = queue
        var error = [CChar](repeating: 0, count: 256)
        bluez = elis_bluez_open({ context, event, message in
            Unmanaged<BlueZRadio>.fromOpaque(context!).takeUnretainedValue().handle(event, message.map { String(cString: $0) })
        }, Unmanaged.passUnretained(self).toOpaque(), &error, error.count)
        let reason = String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        // as CoreBluetooth reports the state after the manager exists, so the owner already holds this radio
        queue.async { [self] in
            guard let bluez else {
                owner.relay.settings.log("bluetooth: \(reason)")
                return owner.off("unsupported")
            }
            let bus = DispatchSource.makeReadSource(fileDescriptor: elis_bluez_fd(bluez), queue: queue)
            bus.setEventHandler { [weak self] in self?.process() }
            // sd-bus may hold messages it read during a blocking call, and a reply that never comes times out
            let tick = DispatchSource.makeTimerSource(queue: queue)
            tick.schedule(deadline: .now() + 1, repeating: 1)
            tick.setEventHandler { [weak self] in self?.process() }
            sources = [bus, tick]
            sources.forEach { $0.resume() }
            if elis_bluez_powered(bluez) != 0 { powered() } else { owner.off("powered off") }
            process()
        }
    }

    func advertise(service: UUID, psm: UInt16) {
        guard let bluez else { return }
        elis_bluez_advertise(bluez, service.uuidString.lowercased(), psm)
    }

    func unpublish(_ psm: UInt16) {
        listener?.cancel()
        listener = nil
        if let bluez { elis_bluez_withdraw(bluez) }
    }

    private func process() {
        guard let bluez, elis_bluez_process(bluez) < 0 else { return }
        // shortcut: the handle leaks with the lost bus; serve must be restarted for Bluetooth after the system bus restarts
        sources.forEach { $0.cancel() }
        sources = []
        self.bluez = nil
        owner?.off("unsupported")
    }

    private func handle(_ event: Int32, _ message: String?) {
        switch event {
        case Int32(ELIS_BLUEZ_POWERED): powered()
        case Int32(ELIS_BLUEZ_UNPOWERED): owner?.off("powered off")
        case Int32(ELIS_BLUEZ_ADVERTISING): owner?.advertised()
        case Int32(ELIS_BLUEZ_FAILED):
            let parts = (message ?? "advertising: failed").split(separator: ":", maxSplits: 1)
            let reason = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : "failed"
            owner?.advertisingFailed(String(parts[0]), Self.error(reason))
        default: break
        }
    }

    /// The adapter is on: listen on a fresh PSM, which the owner then advertises.
    private func powered() {
        guard let owner, owner.psm == nil else { return }
        var psm: UInt16 = 0
        let fd = elis_l2cap_listen(&psm)
        guard fd >= 0 else { return owner.failed("publish", Self.error(String(cString: strerror(errno)))) }
        let listener = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        listener.setEventHandler { [weak self] in
            while true {
                var mtu: Int32 = 0
                let client = elis_l2cap_accept(fd, &mtu)
                guard client >= 0 else {
                    if errno == EINTR || errno == ECONNABORTED { continue }
                    return // EAGAIN, or out of descriptors until the pre-auth cap frees some
                }
                guard let owner = self?.owner else {
                    Glibc.close(client)
                    return
                }
                owner.accept(socket: client, mtu: Int(mtu))
            }
        }
        listener.setCancelHandler { Glibc.close(fd) }
        listener.resume()
        self.listener = listener
        owner.published(psm)
    }

    private static func error(_ reason: String) -> any Error {
        NSError(domain: "bluez", code: 0, userInfo: [NSLocalizedDescriptionKey: reason])
    }
}

/// An L2CAP channel's socket, driven on the relay queue like `OpenSSLPhoneConnection`. Each send is one SDU of at
/// most `mtu` bytes; `BleFramer` rebuilds the stream on both ends.
final class SocketPipe: BlePipe, @unchecked Sendable {
    private let fd: Int32
    private let mtu: Int
    private let queue: DispatchQueue
    private let limits: BlePhoneLink.Limits
    private let reads: DispatchSourceRead
    private let writes: DispatchSourceWrite
    private var received: (@Sendable (Data) -> Void)?
    private var failed: (@Sendable () -> Void)?
    /// `writes` is resumed: only while the socket refuses more, or it fires without end.
    private var writing = false
    private var closing = false
    private var shut = false
    private var pending = Data()
    private var flushed = 0
    private var sends: [(end: Int, completion: () -> Void)] = []

    /// Takes `fd`, a non-blocking socket. Call on `queue`.
    init(fd: Int32, mtu: Int, queue: DispatchQueue, limits: BlePhoneLink.Limits) {
        self.fd = fd
        self.mtu = max(mtu, 1)
        self.queue = queue
        self.limits = limits
        reads = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        writes = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        // the descriptor closes only after both sources let go of it, so its number cannot come back under one
        let released = DispatchGroup()
        released.enter()
        released.enter()
        reads.setCancelHandler { released.leave() }
        writes.setCancelHandler { released.leave() }
        released.notify(queue: queue) { Glibc.close(fd) }
        // strong: the pipe lives until its sources are cancelled, as the Mac's streams hold theirs
        reads.setEventHandler { self.read() }
        writes.setEventHandler { self.pump() }
    }

    func start(received: @escaping @Sendable (Data) -> Void, failed: @escaping @Sendable () -> Void) {
        self.received = received
        self.failed = failed
        reads.resume()
    }

    func write(_ bytes: Data, completion: @escaping () -> Void) {
        guard !shut else { return complete(completion) }
        pending += bytes
        sends.append((flushed + pending.count, completion))
        guard pending.count <= limits.maxPending else { return fail() }
        pump()
    }

    func close() {
        guard !shut, !closing else { return }
        closing = true
        guard !pending.isEmpty else { return shutDown() }
        // a phone that stops reading cannot hold the channel open
        queue.asyncAfter(deadline: .now() + limits.flushTimeout) { self.shutDown() }
    }

    private func read() {
        var buffer = [UInt8](repeating: 0, count: 65536) // an SDU larger than the buffer would be cut short
        while !shut {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count > 0 {
                received?(Data(buffer[0..<count]))
            } else if count < 0, errno == EINTR {
                continue
            } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                return fail() // the phone closed, or the link was lost
            }
        }
    }

    private func pump() {
        while !shut, !pending.isEmpty {
            let count = pending.withUnsafeBytes { send(fd, $0.baseAddress!, min($0.count, mtu), Int32(MSG_NOSIGNAL)) }
            if count > 0 {
                pending.removeFirst(count)
                flushed += count
            } else if count < 0, errno == EINTR {
                continue
            } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                break
            } else {
                return fail()
            }
        }
        let done = sends.prefix { $0.end <= flushed }
        sends.removeFirst(done.count)
        done.forEach { complete($0.completion) }
        if closing, pending.isEmpty { return shutDown() }
        wantWrite(!pending.isEmpty)
    }

    private func wantWrite(_ wanted: Bool) {
        guard wanted != writing, !shut else { return }
        writing = wanted
        if wanted { writes.resume() } else { writes.suspend() }
    }

    private func fail() {
        let failed = failed
        shutDown()
        if let failed { queue.async(execute: failed) }
    }

    /// Every send still waiting completes, as the session's contract needs.
    private func shutDown() {
        guard !shut else { return }
        shut = true
        reads.cancel()
        writes.cancel()
        if !writing { writes.resume() } // a suspended source must not be released
        writing = true
        sends.forEach { complete($0.completion) }
        sends = []
        pending = Data()
    }

    private func complete(_ completion: @escaping () -> Void) {
        nonisolated(unsafe) let work = completion
        queue.async { work() }
    }
}
#endif
