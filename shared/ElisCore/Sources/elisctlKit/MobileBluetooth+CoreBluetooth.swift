#if os(macOS)
import CoreBluetooth
import Foundation

extension MobileBluetooth {
    func makeRadio() -> any BleRadio { CoreBluetoothRadio(owner: self, queue: relay.queue) }

    /// Serves one L2CAP channel's streams; `channel` is kept alive with them. Call on `relay.queue`.
    func accept(input: InputStream, output: OutputStream, holding channel: AnyObject?) {
        accept(StreamPipe(input: input, output: output, holding: channel, queue: relay.queue, limits: limits))
    }
}

/// The Mac's peripheral. CoreBluetooth calls back on `relay.queue`, which is the queue it was created on.
private final class CoreBluetoothRadio: NSObject, CBPeripheralManagerDelegate, BleRadio, @unchecked Sendable {
    private weak var owner: MobileBluetooth?
    private var manager: CBPeripheralManager?
    private var service: CBMutableService?

    init(owner: MobileBluetooth, queue: DispatchQueue) {
        self.owner = owner
        super.init()
        manager = CBPeripheralManager(delegate: self, queue: queue)
    }

    func advertise(service uuid: UUID, psm: UInt16) {
        guard let manager else { return }
        manager.stopAdvertising()
        if let service { manager.remove(service) }
        let value = withUnsafeBytes(of: psm.littleEndian) { Data($0) }
        let characteristic = CBMutableCharacteristic(type: CBUUID(nsuuid: BleIDs.psmCharacteristic), properties: .read,
                                                     value: value, permissions: .readable)
        let service = CBMutableService(type: CBUUID(nsuuid: uuid), primary: true)
        service.characteristics = [characteristic]
        self.service = service
        manager.add(service)
    }

    func unpublish(_ psm: UInt16) {
        manager?.unpublishL2CAPChannel(psm)
        service = nil
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            // a repeated poweredOn with a channel still published would publish a second PSM and leak the first
            guard owner?.psm == nil else { break }
            // the radio coming back finds the old channel and service gone; unverified on hardware, see Task 8
            peripheral.removeAllServices()
            peripheral.publishL2CAPChannel(withEncryption: false)
        case .poweredOff, .resetting: owner?.off("powered off")
        case .unauthorized: owner?.off("unauthorized")
        case .unsupported: owner?.off("unsupported")
        default: break
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didPublishL2CAPChannel PSM: CBL2CAPPSM, error: (any Error)?) {
        if let error { owner?.failed("publish", error); return }
        owner?.published(PSM)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: (any Error)?) {
        if let error { owner?.advertisingFailed("service", error); return }
        // the service UUID only: a local name would expose the Mac's name
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [service.uuid]])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: (any Error)?) {
        if let error { owner?.advertisingFailed("advertising", error); return }
        owner?.advertised()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: (any Error)?) {
        guard let channel, let input = channel.inputStream, let output = channel.outputStream else { return }
        owner?.accept(input: input, output: output, holding: channel)
    }
}

/// An L2CAP channel's streams, which live on `StreamThread`.
private final class StreamPipe: NSObject, BlePipe, StreamDelegate, @unchecked Sendable {
    private let queue: DispatchQueue
    private let limits: BlePhoneLink.Limits

    // stream thread only
    private let input: InputStream
    private let output: OutputStream
    private var received: (@Sendable (Data) -> Void)?
    private var failed: (@Sendable () -> Void)?
    /// The channel, and this pipe itself while its streams are open: a stream's delegate is not retained.
    private var held: [AnyObject] = []
    private var pending = Data()
    private var flushed = 0
    private var sends: [(end: Int, completion: () -> Void)] = []
    private var closing = false
    private var pumpTimer: Timer?

    init(input: InputStream, output: OutputStream, holding channel: AnyObject?, queue: DispatchQueue,
         limits: BlePhoneLink.Limits) {
        self.input = input
        self.output = output
        self.queue = queue
        self.limits = limits
        super.init()
        held = [channel, self].compactMap { $0 }
    }

    func start(received: @escaping @Sendable (Data) -> Void, failed: @escaping @Sendable () -> Void) {
        StreamThread.shared.perform { [self] in
            self.received = received
            self.failed = failed
            for stream in [input, output] as [Stream] {
                stream.delegate = self
                stream.schedule(in: .current, forMode: .default)
                stream.open()
            }
        }
    }

    func close() {
        StreamThread.shared.perform { [self] in
            closing = true
            guard !pending.isEmpty, !held.isEmpty else { return shut() }
            // a phone that stops reading cannot hold the channel open
            DispatchQueue.global().asyncAfter(deadline: .now() + limits.flushTimeout) { StreamThread.shared.perform { self.shut() } }
        }
    }

    func write(_ bytes: Data, completion: @escaping () -> Void) {
        StreamThread.shared.perform { [self] in
            guard !held.isEmpty else { return queue.async(execute: completion) }
            pending += bytes
            sends.append((flushed + pending.count, completion))
            guard pending.count <= limits.maxPending else {
                shut()
                return fail()
            }
            pump()
        }
    }

    private func fail() {
        if let failed { queue.async(execute: failed) }
    }

    // MARK: stream thread

    func stream(_ stream: Stream, handle event: Stream.Event) {
        switch event {
        case .hasBytesAvailable: read()
        case .hasSpaceAvailable: pump()
        case .errorOccurred, .endEncountered:
            shut()
            fail()
        default: break
        }
    }

    private func read() {
        var bytes = [UInt8](repeating: 0, count: 16384)
        var data = Data()
        while input.hasBytesAvailable {
            let count = input.read(&bytes, maxLength: bytes.count)
            guard count > 0 else { break }
            data.append(bytes, count: count)
        }
        if !data.isEmpty, let received { queue.async { received(data) } }
    }

    private func pump() {
        while !pending.isEmpty, output.hasSpaceAvailable {
            let count = pending.withUnsafeBytes { output.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: $0.count) }
            guard count > 0 else { break } // a failure arrives as an event
            pending.removeFirst(count)
            flushed += count
        }
        let done = sends.prefix { $0.end <= flushed }
        sends.removeFirst(done.count)
        done.forEach { queue.async(execute: $0.completion) }
        if closing, pending.isEmpty { return shut() }
        if pending.isEmpty {
            pumpTimer?.invalidate()
            pumpTimer = nil
        } else if pumpTimer == nil {
            let timer = Timer(timeInterval: limits.pumpInterval, repeats: true) { [weak self] _ in self?.pump() }
            RunLoop.current.add(timer, forMode: .default)
            pumpTimer = timer
        }
    }

    /// Closes the streams; every send still waiting completes, as the session's contract needs.
    private func shut() {
        guard !held.isEmpty else { return }
        pumpTimer?.invalidate()
        pumpTimer = nil
        for stream in [input, output] as [Stream] {
            stream.delegate = nil
            stream.close()
            stream.remove(from: .current, forMode: .default)
        }
        sends.forEach { queue.async(execute: $0.completion) }
        sends = []
        pending = Data()
        held = []
    }
}

/// NSStream events need a run loop, and serve parks the main thread in `dispatchMain`: one thread runs the run
/// loop every Bluetooth link's streams are scheduled on.
private final class StreamThread: @unchecked Sendable {
    static let shared = StreamThread()
    private var loop: CFRunLoop?

    private init() {
        let started = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            loop = CFRunLoopGetCurrent()
            RunLoop.current.add(Port(), forMode: .default) // a run loop without a source returns at once
            started.signal()
            while true { RunLoop.current.run() }
        }
        thread.name = "elisctl.mobile.bluetooth"
        thread.start()
        started.wait()
    }

    /// Blocks run in order on the stream thread, which is what serializes the stream-side state.
    func perform(_ block: @escaping () -> Void) {
        nonisolated(unsafe) let work = block
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { work() }
        CFRunLoopWakeUp(loop)
    }
}
#endif
