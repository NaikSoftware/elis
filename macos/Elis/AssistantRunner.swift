import Darwin
import ElisCore
import Foundation

/// AssistantRunner runs the chat's provider CLI: one input per turn, the rest queued, each finished turn recorded in the
/// chat. It follows linux/src/app/assistantrunner.cpp case by case.
@MainActor
final class AssistantRunner {
    var peers: () -> [AssistantPeer] = { [] }
    var emit: (AssistantEntry) -> Void = { _ in }
    var changed: () -> Void = {}
    var pid: Int32? { process?.isRunning == true ? process?.processIdentifier : nil }

    private let chat: AssistantChat
    private let stateDirectory: URL?
    private let standIn: [String]?
    private let baseEnvironment: [String: String]
    private let appPid: pid_t
    private let now: () -> Date

    private var queue: [String] = []
    private var current = ""
    private var busy = false
    private var waitingForDetection = false
    private var provider: SessionLauncher?
    private var mode = AssistantMode.stream
    private var launchEnvironment: [String: String] = [:]
    private var preamble = ""
    private var fresh = false
    private var recap = false
    private var resumed = false
    private var conversed = false
    private var ended = false
    private var turnError: String?
    private var text: [String] = []
    private var lastError = ""
    private var lastOutput = Date.distantPast
    private var watchdog: Timer?

    private var process: Process?
    private var stdin: FileHandle?
    private(set) var guardian: Process?
    private var stdout = Data()
    private let writer = DispatchQueue(label: "ua.naiksoftware.elis.assistant-writer")

    init(chat: AssistantChat, stateDirectory: URL?, standIn: [String]?,
         baseEnvironment: [String: String] = ProcessInfo.processInfo.environment, appPid: pid_t = getpid(),
         now: @escaping () -> Date = Date.init) {
        self.chat = chat
        self.stateDirectory = stateDirectory
        self.standIn = standIn
        self.baseEnvironment = baseEnvironment
        self.appPid = appPid
        self.now = now
    }

    // shortcut: splits on whitespace, so a stand-in path cannot hold a space; quote parsing if one ever must.
    static func standInFromEnvironment() -> [String]? {
        let words = (ProcessInfo.processInfo.environment["ELIS_ASSISTANT_PROVIDER_CMD"] ?? "").split(separator: " ").map(String.init)
        return words.isEmpty ? nil : words
    }

    /// endLeftover ends the provider a hard-killed app left running: a busy one reads stdin only between turns, so it
    /// misses the EOF. The pidfile's start time keeps a reused pid alive.
    static func endLeftover(stateDirectory: URL?) {
        guard let file = stateDirectory.map(pidfile),
              let words = (try? String(contentsOf: file, encoding: .utf8))?.split(whereSeparator: \.isWhitespace),
              words.count == 2, let pid = pid_t(words[0]) else { return }
        try? FileManager.default.removeItem(at: file)
        let started = String(words[1])
        guard startTime(pid) == started else { return }
        kill(pid, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if startTime(pid) == started { kill(pid, SIGKILL) } }
    }

    nonisolated static func startTime(_ pid: pid_t) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return "\(info.pbi_start_tvsec).\(info.pbi_start_tvusec)"
    }

    private static func pidfile(_ stateDirectory: URL) -> URL {
        stateDirectory.appendingPathComponent("assistant/provider.pid")
    }

    private func forgetPid() {
        if let stateDirectory { try? FileManager.default.removeItem(at: Self.pidfile(stateDirectory)) }
    }

    /// The stand-in plays every provider, so tests and isolated instances need no installed agent.
    func providers() -> [SessionLauncher] {
        AssistantProvider.choices(standIn != nil ? SessionLauncher.allCases : SessionLaunchers.cached)
    }

    func enqueue(_ streamText: String) {
        queue.append(streamText)
        pump()
    }

    func providerChanged(_ provider: SessionLauncher) {
        guard provider != self.provider else { return }
        stop(wait: false)
        recap = true
        if busy { // the new provider takes the cut turn over
            queue.insert(current, at: 0)
            busy = false
        }
        pump()
    }

    func clear() {
        stop(wait: false) // a stream provider still holds the forgotten conversation
        queue = []
        busy = false
        text = []
        recap = false
    }

    func stopForQuit() { stop(wait: true) }

    func checkWatchdog() {
        guard busy, now().timeIntervalSince(lastOutput) >= 600 else { return }
        stop(wait: false)
        fail("the assistant stopped responding")
    }

    static func environment(base: [String: String], stateDirectory: String, path: String,
                            launch: [String: String]) -> [String: String] {
        // a parent Claude Code session's markers, which would make the provider its child; CLAUDE_CONFIG_DIR stays
        let markers: Set = ["CLAUDECODE", "CLAUDE_PID", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_EXECPATH",
                            "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_CHILD_NOTES_DIR", "CLAUDE_CODE_SESSION_ID",
                            "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_SSE_PORT", "CLAUDE_CODE_MESSAGING_SOCKET",
                            "CLAUDE_CODE_MESSAGING_TOKEN"]
        var environment = base.filter { !$0.key.hasPrefix("ELIS_") && !markers.contains($0.key) }
        environment["ELIS_STATE_DIR"] = stateDirectory
        environment["PATH"] = path
        environment.merge(launch) { _, new in new }
        return environment
    }

    private func pump() {
        guard !busy, !queue.isEmpty else { return }
        guard stateDirectory != nil else { return fail("the assistant is off in this instance") }
        if standIn == nil, SessionLaunchers.path == nil { // inputs wait for the first detection
            guard !waitingForDetection else { return }
            waitingForDetection = true
            Task { @MainActor [weak self] in
                await SessionLaunchers.settled()
                self?.waitingForDetection = false
                self?.pump()
            }
            return
        }
        guard let provider = provider ?? launch() else { return }
        current = queue.removeFirst()
        busy = true
        ended = false
        text = []
        turnError = nil
        lastError = ""
        armWatchdog()
        var input = current
        if fresh {
            let recap = recap ? AssistantPrompt.inline(chat.settledEntries(last: 50)) : ""
            input = preamble + (recap.isEmpty ? "" : recap + "\n\n") + input
            fresh = false
        }
        if mode == .stream {
            write(AssistantStream.encode(provider, text: input) + "\n")
        } else {
            spawn(AssistantProvider.turn(provider, input: input, prompt: prompt(), resume: chat.resume[provider]))
        }
        if process != nil { recap = false } // a start that failed keeps it for the next, as Linux clears it on `started`
    }

    private func launch() -> SessionLauncher? {
        let available = AssistantProvider.choices(standIn != nil ? SessionLauncher.allCases : SessionLaunchers.available)
        let saved = chat.provider.flatMap { available.contains($0) ? $0 : nil } // one no longer installed is dropped
        guard let chosen = saved ?? available.first else {
            fail("no assistant provider installed")
            return nil
        }
        if saved == nil { chat.provider = chosen } // saved, so the tree reads it back and a later detection never swaps it
        let launch = AssistantProvider.launch(chosen, prompt: prompt(), resume: chat.resume[chosen])
        provider = chosen
        mode = launch.mode
        launchEnvironment = launch.environment
        preamble = launch.preamble ?? ""
        fresh = true
        if mode == .stream { spawn(launch.argv) }
        return provider // a process that could not start has failed the queue already
    }

    private func prompt() -> String { AssistantPrompt.system(AssistantDirectory(peers())) }

    private func spawn(_ argv: [String]) {
        guard let stateDirectory, let provider, !argv.isEmpty else { return }
        var argv = argv
        if let standIn { argv = standIn + argv.dropFirst() } // tests run a fake in the provider binary's place
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS").path
        let path = bundled + ":" + (SessionLaunchers.path ?? baseEnvironment["PATH"] ?? "")
        let directory = stateDirectory.appendingPathComponent("assistant", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.resolve(argv[0], path: path))
        process.arguments = Array(argv.dropFirst())
        process.environment = Self.environment(base: baseEnvironment, stateDirectory: stateDirectory.path, path: path,
                                               launch: launchEnvironment)
        process.currentDirectoryURL = directory
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let input = mode == .stream ? Pipe() : nil
        process.standardInput = input ?? FileHandle.nullDevice
        resumed = !(chat.resume[provider] ?? "").isEmpty
        conversed = false
        stdout = Data()
        self.process = process
        stdin = input?.fileHandleForWriting
        if let input { _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) }
        let exited = Exit()
        process.terminationHandler = { @Sendable [weak self] process in
            let status = process.terminationStatus, crashed = process.terminationReason == .uncaughtSignal
            DispatchQueue.main.async {
                exited.status = (status, crashed)
                self?.finishIfDone(process, exited, provider: provider)
            }
        }
        errors.fileHandleForReading.readabilityHandler = { @Sendable [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            let line = String(decoding: data, as: UTF8.self).split(separator: "\n").last?.trimmingCharacters(in: .whitespaces)
            DispatchQueue.main.async {
                guard let self, self.process === process, let line, !line.isEmpty else { return }
                self.lastError = line
            }
        }
        do {
            try process.run()
        } catch {
            self.process = nil
            stdin = nil
            self.provider = nil
            fail("Cannot run \(argv[0]): \(error.localizedDescription)")
            return
        }
        if let started = Self.startTime(process.processIdentifier) {
            try? "\(process.processIdentifier) \(started)\n".write(to: Self.pidfile(stateDirectory), atomically: true, encoding: .utf8)
        }
        guardProvider(process.processIdentifier)
        // One reader posts chunks then EOF in order, so the exit is handled after the last output line.
        let reader = output.fileHandleForReading
        DispatchQueue.global().async { @Sendable [weak self] in
            while case let data = reader.availableData, !data.isEmpty { // read(upToCount:) would wait for a full buffer
                DispatchQueue.main.async { self?.received(data, from: process) }
            }
            DispatchQueue.main.async {
                exited.eof = true
                self?.finishIfDone(process, exited, provider: provider)
            }
        }
    }

    /// guardProvider stops the provider when the app dies: a hard-killed app runs no teardown, and a busy provider reads
    /// stdin only between turns. The guard outlives the app and exits with the provider.
    private func guardProvider(_ pid: pid_t) {
        let guardian = Process()
        guardian.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Process makes the provider its own group's leader, so the group signal reaches its children too.
        guardian.arguments = ["-c", """
            while kill -0 "$1" 2>/dev/null && kill -0 "$2" 2>/dev/null; do sleep 1; done
            kill -0 "$1" 2>/dev/null && exit 0
            kill -TERM -"$2" 2>/dev/null || exit 0
            sleep 3
            kill -KILL -"$2" 2>/dev/null
            """, "elis-assistant-guard", String(appPid), String(pid)]
        guardian.standardInput = FileHandle.nullDevice
        guardian.standardOutput = FileHandle.nullDevice
        guardian.standardError = FileHandle.nullDevice
        try? guardian.run()
        self.guardian = guardian
    }

    private final class Exit: @unchecked Sendable { // touched on the main queue only
        var status: (code: Int32, crashed: Bool)?
        var eof = false
    }

    private static func resolve(_ name: String, path: String) -> String {
        guard !name.contains("/") else { return name }
        return path.split(separator: ":").lazy.map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? name
    }

    private func write(_ line: String) {
        guard let stdin else { return }
        let data = Data(line.utf8)
        writer.async { try? stdin.write(contentsOf: data) } // off main: a provider not reading must not block the app
    }

    private func received(_ data: Data, from process: Process) {
        guard self.process === process else { return }
        if busy { lastOutput = now() }
        stdout.append(data)
        while let newline = stdout.firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: stdout[stdout.startIndex..<newline], as: UTF8.self)
            stdout.removeSubrange(stdout.startIndex...newline)
            decoded(line)
        }
    }

    private func decoded(_ line: String) {
        guard let provider else { return }
        for event in AssistantStream.decode(provider, line: line) {
            guard busy else { return } // output outside a turn joins no reply
            switch event {
            case let .text(chunk): text.append(chunk)
            case let .conversation(id):
                chat.resume[provider] = id
                conversed = true
            case let .turnEnded(error):
                if mode == .perInput { // its process exit ends the turn, so no two ever overlap
                    ended = true
                    turnError = error
                } else {
                    endTurn(error)
                }
            }
        }
    }

    private func finishIfDone(_ process: Process, _ exited: Exit, provider: SessionLauncher) {
        guard self.process === process, exited.eof, let (code, crashed) = exited.status else { return }
        self.process = nil
        forgetPid()
        stdin = nil
        if mode == .stream { self.provider = nil } // the next input starts it again, resuming its conversation
        guard busy else { return }
        if mode == .perInput, ended || (!crashed && code == 0) { return endTurn(turnError) }
        if resumed, !conversed {
            // It died before naming its conversation: the stored one is gone, and resuming it again would fail every
            // launch. The input goes once more to a fresh conversation, with the chat inlined.
            chat.resume[provider] = nil
            self.provider = nil
            busy = false
            recap = true
            text = []
            queue.insert(current, at: 0)
            return pump()
        }
        let name = process.executableURL?.lastPathComponent ?? "provider"
        let why = crashed ? "\(name) crashed" : "\(name) exited with status \(code)"
        fail(lastError.isEmpty ? why : "\(why): \(lastError)")
    }

    private func endTurn(_ error: String?) {
        if !text.isEmpty {
            emit(chat.append(.assistant, text: text.joined(separator: "\n\n"), now: now().timeIntervalSince1970))
        }
        text = []
        busy = false
        disarmWatchdog()
        if let error {
            emit(chat.turnFailed(error, now: now().timeIntervalSince1970))
        } else {
            chat.turnEnded()
        }
        changed() // a turn with no text emits nothing, and its end still clears the working state
        pump()
    }

    private func fail(_ message: String) {
        queue = []
        busy = false
        text = []
        disarmWatchdog()
        chat.providerFailed(message, now: now().timeIntervalSince1970)
        if let entry = chat.entries(last: 1).first { emit(entry) }
        changed()
    }

    private func armWatchdog() {
        lastOutput = now()
        guard watchdog == nil else { return }
        watchdog = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkWatchdog() }
        }
    }

    private func disarmWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    private func stop(wait: Bool) {
        provider = nil
        disarmWatchdog()
        guard let process else { return }
        self.process = nil
        stdin = nil
        forgetPid()
        guard process.isRunning else { return }
        process.terminate() // SIGTERM first, so the provider can end what it started
        let pid = process.processIdentifier
        guard wait else {
            // shortcut: SIGKILL orphans claude's own-group tool children (Bash, MCP); walk the tree if one is ever seen surviving
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if process.isRunning { kill(pid, SIGKILL) } }
            return
        }
        let deadline = Date().addingTimeInterval(2)
        while kill(pid, 0) == 0, Date() < deadline { usleep(10_000) }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }
}
