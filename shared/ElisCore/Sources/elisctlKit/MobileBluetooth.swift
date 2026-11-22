#if !canImport(Musl)
import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// The platform's BLE peripheral under `MobileBluetooth`: Core Bluetooth on the Mac, BlueZ on Linux.
/// Every call, and every call it makes back, is on `relay.queue`.
public protocol BleRadio: AnyObject {
    /// Reports to `owner`, on `queue`, once the radio is on, as Core Bluetooth reports after the manager exists.
    init(owner: MobileBluetooth, queue: DispatchQueue)
    /// Serves `psm` in the PSM characteristic under `service` and advertises that UUID, replacing the last one.
    func advertise(service: UUID, psm: UInt16)
    /// Ends the L2CAP channel `psm` and what advertised it; open channels are not touched.
    func unpublish(_ psm: UInt16)
}

/// The relay's Bluetooth transport: a BLE peripheral advertising the token's rotating service UUID, whose L2CAP
/// channels become phones of the relay. Every mutable property is touched on `relay.queue`.
public final class MobileBluetooth: @unchecked Sendable {
    public let relay: MobileRelay
    private let token: String
    /// Authenticated Bluetooth phones at once; a handshake past it gets the busy frame. Links that passed the
    /// handshake but never authenticate (a replayed message 1) are the relay's unauthenticated cap's to evict.
    private let maxPhones: Int
    public let limits: BlePhoneLink.Limits
    private let status: @Sendable (String) -> Void
    private var shown: String?
    private var links: [ObjectIdentifier: BlePhoneLink] = [:]
    private var radio: (any BleRadio)?
    /// The published L2CAP channel, nil while the radio is off.
    public private(set) var psm: UInt16?
    private var rotation: (any DispatchSourceTimer)?
    private var lock: Int32 = -1

    /// `status` gets `advertising` or `off (<reason>)`, once per change.
    init(relay: MobileRelay, token: String, maxPhones: Int = 8, limits: BlePhoneLink.Limits = .init(),
         status: @escaping @Sendable (String) -> Void) {
        self.relay = relay
        self.token = token
        self.maxPhones = maxPhones
        self.limits = limits
        self.status = status
    }

    /// Takes the per-state-directory lock and starts the peripheral; false when this relay will not offer
    /// Bluetooth. The lock is held for the life of the process.
    @discardableResult
    func start() -> Bool {
        let path = relay.settings.mobileDir + "/bluetooth.lock"
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            relay.settings.log("bluetooth: cannot open \(path): \(String(cString: strerror(errno)))")
            relay.queue.sync { report("off (unsupported)") }
            return false
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            relay.queue.sync { report("off (in use by another relay)") }
            return false
        }
        relay.queue.sync {
            lock = fd
            radio = makeRadio()
            if radio == nil { off("unsupported") }
        }
        return true
    }

    private func makeRadio() -> (any BleRadio)? { MobileTransports.radio?.init(owner: self, queue: relay.queue) }

    /// Serves one L2CAP channel. Call on `relay.queue`.
    public func accept(_ pipe: any BlePipe) {
        let link = BlePhoneLink(pipe: pipe, queue: relay.queue, mobileDir: relay.settings.mobileDir) { [weak self] in
            guard let self else { return false }
            return relay.authenticatedPhones { $0 is BlePhoneLink } < maxPhones
        }
        link.onEnd = { [weak self] in self?.links[ObjectIdentifier($0)] = nil }
        links[ObjectIdentifier(link)] = link
        // the session's auth timeout and unauthenticated cap also cover a channel that never sends message 1
        relay.accept(link)
        link.start()
    }

    /// The radio went away: every Bluetooth phone is dropped, so its session gives back its grids. Call on `relay.queue`.
    public func off(_ reason: String) {
        report("off (\(reason))")
        rotation?.cancel()
        rotation = nil
        if let psm { radio?.unpublish(psm) }
        psm = nil
        links.values.forEach { $0.drop() }
    }

    private func report(_ state: String) {
        guard state != shown else { return }
        shown = state
        status(state)
    }

    /// Publishing the channel failed: the radio is off for this relay. Call on `relay.queue`.
    public func failed(_ step: String, _ error: any Error) {
        relay.settings.log("bluetooth \(step) failed: \(error.localizedDescription)")
        off("unsupported")
    }

    /// Registering or advertising failed: open channels and the PSM stay, and the next try comes in 30 s.
    /// Call on `relay.queue`.
    public func advertisingFailed(_ step: String, _ error: any Error) {
        relay.settings.log("bluetooth \(step) failed: \(error.localizedDescription)")
        report("off (unsupported)")
        schedule(after: 30)
    }

    /// The radio published its L2CAP channel. Call on `relay.queue`.
    public func published(_ psm: UInt16) {
        self.psm = psm
        advertise()
    }

    /// The radio advertises the last service. Call on `relay.queue`.
    public func advertised() { report("advertising") }

    private func schedule(after delay: TimeInterval) {
        let rotation = DispatchSource.makeTimerSource(queue: relay.queue)
        rotation.schedule(wallDeadline: .now() + delay)
        rotation.setEventHandler { [weak self] in self?.advertise() }
        rotation.resume()
        self.rotation?.cancel()
        self.rotation = rotation
    }

    /// Registers the PSM characteristic under this epoch's UUID and advertises it, then again at the next boundary.
    /// Open channels are not touched.
    private func advertise() {
        guard let radio, let psm else { return }
        let now = Date()
        let epoch = BleIDs.epoch(at: now)
        radio.advertise(service: BleIDs.serviceUUID(token: token, epoch: epoch), psm: psm)
        schedule(after: Double(epoch + 1) * BleIDs.epochSeconds - now.timeIntervalSince1970)
    }
}

/// The bytes under a `BlePhoneLink`: Core Bluetooth's streams on the Mac, an L2CAP socket on Linux.
public protocol BlePipe: AnyObject {
    /// Starts reading. Both run on the relay queue; `failed` once the peer is gone or stopped reading.
    func start(received: @escaping @Sendable (Data) -> Void, failed: @escaping @Sendable () -> Void)
    /// `completion` runs on the relay queue once the bytes are written, or the pipe has shut.
    func write(_ bytes: Data, completion: @escaping () -> Void)
    /// Shuts once queued output drains, or after `Limits.flushTimeout`.
    func close()
}

/// One L2CAP channel as a relay phone: the Noise handshake, then sealed frames of the line stream.
/// Protocol state lives on `queue`; the bytes go through `pipe`.
public final class BlePhoneLink: PhoneTransportConnection, @unchecked Sendable {
    public struct Limits: Sendable {
        /// Output not yet written; past it the phone is not reading and is dropped.
        public var maxPending = 8 << 20
        /// How long a close waits for queued output to drain.
        public var flushTimeout: TimeInterval = 5
        /// The spike saw an L2CAP stream stop reporting space mid-transfer, so pending output is also retried on a
        /// timer (the Mac's streams only).
        public var pumpInterval: TimeInterval = 0.02
    }

    public private(set) var peerLabel = "bt"
    public var onReceive: ((Data) -> Void)?
    public var onClose: (() -> Void)?
    var onEnd: ((BlePhoneLink) -> Void)?
    private let pipe: any BlePipe
    private let queue: DispatchQueue
    private let mobileDir: String
    private let admit: () -> Bool
    private var framer = BleFramer()
    private var keys: BleTransportKeys?
    private var ended = false

    /// `admit` says whether one more phone may pass the handshake.
    init(pipe: any BlePipe, queue: DispatchQueue, mobileDir: String, admit: @escaping () -> Bool) {
        self.pipe = pipe
        self.queue = queue
        self.mobileDir = mobileDir
        self.admit = admit
    }

    func start() {
        // weak: the pipe keeps itself while it is open, and the relay keeps the link
        pipe.start(received: { [weak self] in self?.received($0) }, failed: { [weak self] in self?.drop() })
    }

    // MARK: relay queue

    public func send(_ data: Data, completion: @escaping () -> Void) {
        guard !ended, var sealing = keys else { return later(completion) }
        var wire = Data()
        do {
            // seal in call order on this queue: the nonce order is the wire order
            for offset in stride(from: 0, to: data.count, by: BleTransportKeys.maxChunk) {
                let start = data.startIndex + offset
                wire += BleFramer.frame(try sealing.seal(Data(data[start..<min(start + BleTransportKeys.maxChunk, data.endIndex)])))
            }
        } catch {
            later(completion)
            return drop()
        }
        keys = sealing
        pipe.write(wire, completion: completion)
    }

    public func close() {
        guard !ended else { return }
        ended = true
        onEnd?(self)
        pipe.close()
    }

    /// The peer is gone or broke the link: closes after any reject frame drains, and tells the session.
    func drop() {
        close()
        onClose?()
    }

    private func later(_ completion: @escaping () -> Void) {
        nonisolated(unsafe) let work = completion // called on `queue` only; Linux's Dispatch takes @Sendable blocks
        queue.async { work() }
    }

    private func received(_ data: Data) {
        for body in framer.push(data) {
            guard !ended else { return }
            guard keys != nil else {
                handshake(body)
                continue
            }
            do {
                if let plain = try keys?.open(body) { onReceive?(plain) }
            } catch {
                return drop()
            }
        }
    }

    /// Any handshake failure gets the wrong-key frame, so a stranger learns nothing about why.
    private func handshake(_ message: Data) {
        peerLabel = "bt:" + message.prefix(2).map { String(format: "%02x", $0) }.joined()
        guard let token = MobilePairing.currentToken(in: mobileDir),
              let accepted = try? BleResponder(psk: BleIDs.psk(token: token)).readInitiator(message) else { return reject(0x01) }
        guard admit() else { return reject(0x02) }
        keys = accepted.transport
        pipe.write(BleFramer.frame(accepted.reply)) {}
    }

    private func reject(_ code: UInt8) {
        pipe.write(BleFramer.frame(Data([code]))) {}
        drop()
    }
}
#endif
