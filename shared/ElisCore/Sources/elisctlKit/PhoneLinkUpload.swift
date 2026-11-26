#if !canImport(Musl)
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import ElisCore

/// One `upload` channel: asks the app `session.upload` for a destination, then writes `size` bytes from the phone
/// to a local `UploadSink` or into `ssh … elisctl session upload` for a remote row, under a receive window with
/// CREDIT back. Every method and callback runs on the relay queue; the sink and the child's stdin live on `writes`.
final class PhoneLinkUpload: @unchecked Sendable {
    /// How the upload reaches its link; all run on the relay queue.
    struct Link {
        /// Sends a frame that bypasses the scheduler (OPENED, CLOSE).
        let frame: (PhoneLinkFrame) -> Void
        /// Sends CREDIT for `bytes`; `sent` runs once the frame has gone out.
        let credit: (_ bytes: UInt32, _ sent: @escaping () -> Void) -> Void
        /// The channel is over: the link forgets this upload.
        let ended: () -> Void
    }

    /// Bytes the phone may send ahead of CREDIT; the phone uses the same value.
    static let window = 16384
    static let updateLocal = "Update Elis on the computer to attach files"

    let channel: UInt32
    private let target: String
    private let name: String
    private let size: Int
    private let socketPath: String
    private let queue: DispatchQueue
    private let link: Link
    /// The argv a remote row runs, under `/usr/bin/env`; tests swap the ssh command for a script.
    private let command: ([String]) -> [String]
    private let writes = DispatchQueue(label: "phone-link-upload-writes")
    /// Touched only on `writes`; nil once finished or abandoned, so an abandon never removes a delivered file.
    private var sink: UploadSink?
    /// The remote child's stdin, touched only on `writes`; nil once closed.
    private var stdin: FileHandle?
    private var process: Process?
    private var host = ""
    private var opened = false
    private var stopped = false
    private var completing = false
    private var early: [Data] = []
    private var received = 0
    private var stored = 0
    private var unacknowledged = 0
    private var owed = 0
    private var crediting = false

    init(channel: UInt32, request: PhoneLinkOpen, socketPath: String, queue: DispatchQueue, link: Link,
         command: @escaping ([String]) -> [String] = { $0 }) {
        self.channel = channel
        target = request.target
        name = UploadStorage.safeName(request.name ?? "")
        size = request.size ?? 0
        self.socketPath = socketPath
        self.queue = queue
        self.link = link
        self.command = command
    }

    /// The OPEN's refusal, checked before the channel is kept.
    static func refusal(_ request: PhoneLinkOpen, running: Bool) -> String? {
        guard request.name != nil, let size = request.size, size >= 0 else { return "malformed open" }
        if size > UploadLimits.maxBytes { return "file too large (max 20 MiB)" }
        return running ? "an upload is already running" : nil
    }

    func start() {
        let body = (try? JSONSerialization.data(
            withJSONObject: ["cmd": Command.sessionUpload.rawValue, "target": target, "args": ["name": name, "size": size]],
            options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        let socketPath = socketPath
        Thread.detachNewThread { [self] in
            let answer: Result<ControlUpload, PhoneLinkTerminal.Refusal>
            do {
                let line = try SocketClient(path: socketPath).sendRaw(body, timeout: PhoneLinkTerminal.attachTimeout)
                let reply = try JSONDecoder().decode(ControlResponse.self, from: line)
                if let upload = reply.result?.upload, reply.ok {
                    answer = .success(upload)
                } else {
                    answer = .failure(PhoneLinkTerminal.Refusal(Self.appRefusal(reply)))
                }
            } catch {
                answer = .failure(PhoneLinkTerminal.Refusal("Elis is not reachable: \(error)"))
            }
            queue.async { [self] in answered(answer) }
        }
    }

    /// Past `window` unacknowledged bytes, or past `size`, the channel closes.
    func input(_ bytes: Data) {
        guard !stopped else { return }
        unacknowledged += bytes.count
        received += bytes.count
        if unacknowledged > Self.window || received > size { return close(reason: "input overflow") }
        guard opened else { return early.append(bytes) }
        write(bytes)
    }

    /// Ends the upload without a word to the phone; the sink is abandoned and the child terminated.
    func stop() {
        guard !stopped else { return }
        stopped = true
        early = []
        if let process, process.isRunning { process.terminate() }
        writes.async { [self] in
            sink?.abandon()
            sink = nil
            closeInput()
        }
    }

    static func appRefusal(_ reply: ControlResponse) -> String {
        let error = reply.error ?? "Elis gave no upload path"
        if reply.refusesUnknown(.sessionUpload) || error.contains("too old for session.upload")
            || error.contains("unknown command 'session.upload'") {
            return updateLocal
        }
        return error
    }

    /// The remote `elisctl`'s whole run, read once it has exited.
    static func remoteOutcome(_ result: RemoteCommandResult, host: String) -> Result<String, PhoneLinkTerminal.Refusal> {
        let update = PhoneLinkTerminal.Refusal("Update Elis on \(host) to attach files")
        if result.refusedArguments { return .failure(update) }
        let line = result.stdout.split(separator: "\n").first.map(String.init) ?? ""
        guard let reply = try? JSONDecoder().decode(ControlResponse.self, from: Data(line.utf8)) else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(PhoneLinkTerminal.Refusal("\(host) gave no answer\(stderr.isEmpty ? "" : " (\(stderr))")"))
        }
        if reply.refusesUnknown(.sessionUpload) { return .failure(update) }
        guard reply.ok, let path = reply.result?.upload?.path else {
            return .failure(PhoneLinkTerminal.Refusal(reply.error ?? "\(host) gave no upload path"))
        }
        return .success(path)
    }

    private func answered(_ answer: Result<ControlUpload, PhoneLinkTerminal.Refusal>) {
        guard !stopped else {
            // the app reserved a placeholder for a phone that is gone
            if case .success(let upload) = answer, let path = upload.path { unlink(path) }
            return
        }
        switch answer {
        case .failure(let refusal): refuse(refusal.message)
        case .success(let upload):
            if let path = upload.path {
                openSink(path)
            } else if let host = upload.host, let session = upload.session {
                spawn(host: host, session: session)
            } else {
                refuse("Elis gave no upload path")
            }
        }
    }

    private func openSink(_ path: String) {
        writes.async { [self] in
            let failure: String?
            do {
                sink = try UploadSink(path: URL(fileURLWithPath: path))
                failure = nil
            } catch {
                unlink(path)
                failure = "could not write the upload: \(error.localizedDescription)"
            }
            queue.async { [self] in
                guard !stopped else { return }
                if let failure { return refuse(failure) }
                accepted()
            }
        }
    }

    private func spawn(host: String, session: String) {
        self.host = host
        let argv: [String]
        do {
            argv = command(try RemoteSession.uploadCommand(host: host, session: session, name: name, size: size))
        } catch {
            return refuse("could not start the upload: \(error)")
        }
        let process = Process()
        // env finds a bare `ssh` on PATH and execs it, so terminate() still reaches the command
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.runWithSignals()
        } catch {
            return refuse("could not start the upload: \(error)")
        }
        let handle = stdin.fileHandleForWriting
        // a child that stopped reading fails the write with EPIPE instead of raising SIGPIPE in the relay
        #if canImport(Darwin)
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
        #else
        signal(SIGPIPE, SIG_IGN) // a pipe has no such flag on Linux
        #endif
        self.process = process
        writes.async { [self] in self.stdin = handle }
        watch(process, stdout: stdout, stderr: stderr)
        accepted()
    }

    /// Reads the child's output to its end and reaps it; its result closes the channel unless it was stopped.
    private func watch(_ process: Process, stdout: Pipe, stderr: Pipe) {
        let errors = Collected()
        Thread.detachNewThread { errors.set(stderr.fileHandleForReading.readDataToEndOfFile()) }
        Thread.detachNewThread { [self] in
            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let result = RemoteCommandResult(status: process.terminationStatus, stdout: String(decoding: output, as: UTF8.self),
                                             stderr: String(decoding: errors.wait(), as: UTF8.self))
            queue.async { [self] in
                guard !stopped else { return }
                switch Self.remoteOutcome(result, host: host) {
                case .success(let path) where completing: close(reason: "uploaded", path: path)
                case .success: close(reason: "\(host) ended the upload early")
                case .failure(let refusal): close(reason: refusal.message)
                }
            }
        }
    }

    private func accepted() {
        opened = true
        link.frame(.json(.opened, channel: channel, PhoneLinkOpened()))
        let waiting = early
        early = []
        waiting.forEach(write)
        if size == 0 { complete() }
    }

    private func write(_ bytes: Data) {
        writes.async { [self] in
            let ok = sink.map { (try? $0.write(bytes)) != nil } ?? true
            // EPIPE is the child's early exit, which its watcher reports
            if let stdin, !StreamBridge.writeAll(stdin.fileDescriptor, bytes) { closeInput() }
            queue.async { [self] in ok ? written(bytes.count) : close(reason: "could not write the upload") }
        }
    }

    private func written(_ count: Int) {
        guard !stopped else { return }
        stored += count
        owed += count
        sendCredit()
        if stored == size { complete() }
    }

    /// Every byte is in: the sink renames over the placeholder, or the child's stdin closes and its reply decides.
    private func complete() {
        guard !completing else { return }
        completing = true
        guard process == nil else { return writes.async { [self] in closeInput() } }
        writes.async { [self] in
            guard let sink else { return }
            self.sink = nil
            let result = Result { try sink.finish() }
            if case .failure = result { sink.abandon() }
            queue.async { [self] in
                switch result {
                case .success(let url):
                    // the phone left while the rename ran, so the file is nobody's
                    guard !stopped else { unlink(url.path); return }
                    close(reason: "uploaded", path: url.path)
                case .failure(let error):
                    close(reason: "could not write the upload: \(error.localizedDescription)")
                }
            }
        }
    }

    private func closeInput() {
        try? stdin?.close()
        stdin = nil
    }

    private func sendCredit() {
        guard !stopped, !crediting, owed > 0 else { return }
        let bytes = owed
        owed = 0
        unacknowledged -= bytes
        crediting = true
        link.credit(UInt32(bytes)) { [weak self] in
            self?.crediting = false
            self?.sendCredit()
        }
    }

    private func refuse(_ message: String) {
        stop()
        link.frame(.json(.opened, channel: channel, PhoneLinkOpened(error: message)))
        link.ended()
    }

    private func close(reason: String, path: String? = nil) {
        stop()
        link.frame(.json(.close, channel: channel, PhoneLinkClose(reason: reason, path: path)))
        link.ended()
    }
}

/// One reader thread's bytes, handed to another once it has read to the end.
private final class Collected: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private var data = Data()

    func set(_ bytes: Data) {
        data = bytes
        done.signal()
    }

    func wait() -> Data {
        done.wait()
        return data
    }
}
#endif
