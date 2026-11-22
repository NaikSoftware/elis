import ArgumentParser
import Dispatch
import Foundation
import ElisCore

struct AssistantAskDependencies {
    let send: (ControlRequest) throws -> SocketReply
    let sleep: (TimeInterval) -> Void
    /// Monotonic seconds, so a wall-clock change cannot stretch or cut the timeout.
    let now: () -> TimeInterval

    static func live(socketPath: String) -> AssistantAskDependencies {
        AssistantAskDependencies(
            send: { request in try SocketClient(path: socketPath).send(request) },
            sleep: Thread.sleep(forTimeInterval:),
            now: { TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }
        )
    }
}

enum AssistantAskOutcome {
    case reply(SocketReply, entryID: UUID?)
    case timedOut
}

/// Assistant is `elisctl assistant`: talk to the Elis assistant and message agent sessions.
struct Assistant: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "assistant",
        abstract: "Talk to the Elis assistant and message agent sessions.",
        subcommands: [Ask.self, Send.self, Read.self, Provider.self, Show.self]
    )

    static func formatEntry(_ entry: AssistantEntry, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        let time = formatter.string(from: Date(timeIntervalSince1970: entry.ts))
        let sender = entry.from.flatMap { $0.isEmpty ? nil : " @\($0)" } ?? ""
        return "\(time) \(entry.kind.rawValue)\(sender): \(entry.text)"
    }
}

extension Assistant {
    struct Ask: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Post a message to the Elis assistant.",
            discussion: """
            assistant ask "what is claude doing?" [--wait [--timeout N]]

            --wait polls until the assistant finishes its turn and prints the new reply; --timeout ends \
            the wait with exit \(timeoutExitCode).
            """
        )

        static let timeoutExitCode: Int32 = 124

        @Argument(help: "Message text for the assistant.")
        var text: String
        @Flag(name: .long, help: "Wait until the assistant finishes its turn.")
        var wait = false
        @Option(name: .long, help: "With --wait, seconds before exiting \(timeoutExitCode); omitted, waits indefinitely.")
        var timeout: Double?
        @OptionGroup var options: BasicOptions

        func validate() throws {
            guard let timeout else { return }
            guard wait else { throw ValidationError("--timeout needs --wait") }
            guard timeout.isFinite, timeout > 0 else { throw ValidationError("--timeout must be a positive number of seconds") }
        }

        func makeRequest() -> ControlRequest {
            ControlRequest(cmd: .assistantAsk, args: ControlArgs(text: text))
        }

        func run() throws {
            let watchdog = timeout.map { seconds in
                SessionWaitWatchdog(seconds: seconds) {
                    Self.reportTimeout()
                    Foundation.exit(Self.timeoutExitCode)
                }
            }
            defer { watchdog?.cancel() }
            switch try ask(dependencies: .live(socketPath: options.socketPath())) {
            case .reply(let reply, let afterID):
                try Msg.emit(Self.output(reply, json: options.json, after: afterID))
            case .timedOut:
                Self.reportTimeout()
                throw ExitCode(Self.timeoutExitCode)
            }
        }

        func ask(dependencies: AssistantAskDependencies) throws -> AssistantAskOutcome {
            let deadline = timeout.map { dependencies.now() + $0 }
            let posted = try dependencies.send(makeRequest())
            guard posted.response.ok, wait else { return .reply(posted, entryID: nil) }
            let postedID = posted.response.result?.assistant?.entries?.first?.id
            var pendingPolls = 0
            while true {
                if let deadline, dependencies.now() >= deadline { return .timedOut }
                let treeReply = try dependencies.send(ControlRequest(cmd: .tree))
                guard treeReply.response.ok else { return .reply(treeReply, entryID: nil) }
                guard treeReply.response.result?.tree?.assistant?.running == true else { break }
                pendingPolls += 1
                let delay = SocketClient.pickPollDelay(afterPendingPoll: pendingPolls)
                if let deadline {
                    let left = deadline - dependencies.now()
                    if left <= 0 { return .timedOut }
                    dependencies.sleep(min(delay, left))
                } else {
                    dependencies.sleep(delay)
                }
            }
            let readReply = try dependencies.send(ControlRequest(cmd: .assistantRead))
            return .reply(readReply, entryID: postedID)
        }

        static func output(_ reply: SocketReply, json: Bool, after postedID: UUID?) -> MessageOutput {
            guard reply.response.ok else { return Msg.refused(reply, json: json) }
            if json { return MessageOutput(stdout: reply.line + "\n") }
            guard let postedID else { return MessageOutput(stdout: "ok\n") }
            let all = reply.response.result?.assistant?.entries ?? []
            let entries = all.lastIndex(where: { $0.id == postedID }).map { Array(all[($0 + 1)...]) } ?? all
            guard !entries.isEmpty else { return MessageOutput(stdout: "ok\n") }
            return MessageOutput(stdout: entries.map { Assistant.formatEntry($0) }.joined(separator: "\n") + "\n")
        }

        private static func reportTimeout() {
            FileHandle.standardError.write(Data("timed out\n".utf8))
        }
    }

    struct Send: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Send a message directly to tagged sessions.",
            discussion: """
            assistant send --to @claude-1 "run the tests"
            assistant send --to @ws:elis --to @zsh --stdin < note.txt
            """
        )

        @Option(name: .customLong("to"), help: "Recipient tag (@handle, @ws:handle, or @all); repeat for several.")
        var recipients: [String] = []
        @Argument(help: "Message text; use --stdin to read it instead.")
        var text: String?
        @Flag(name: .long, help: "Read the message from stdin.")
        var stdin = false
        @OptionGroup var options: BasicOptions

        func validate() throws {
            guard !recipients.isEmpty else { throw ValidationError("provide at least one --to tag") }
            guard (text != nil) != stdin else { throw ValidationError("provide the message as TEXT or --stdin, exactly one") }
        }

        func makeRequest(body: String) -> ControlRequest {
            ControlRequest(cmd: .assistantSend, args: ControlArgs(text: body, recipients: recipients))
        }

        func run() throws {
            let body = try text ?? decodeTypedStdin(FileHandle.standardInput.readDataToEndOfFile())
            let reply = try SocketClient(path: options.socketPath()).send(makeRequest(body: body))
            try Msg.emit(Self.output(reply, json: options.json))
        }

        static func output(_ reply: SocketReply, json: Bool) -> MessageOutput {
            guard reply.response.ok else { return Msg.refused(reply, json: json) }
            let delivered = reply.response.result?.assistant?.delivered ?? []
            if json { return MessageOutput(stdout: reply.line + "\n", failed: delivered.isEmpty) }
            let skipped = reply.response.result?.assistant?.skipped ?? []
            let stderr = skipped.map { "skipped \($0.handle): \($0.reason)\n" }.joined()
            guard !delivered.isEmpty else { return MessageOutput(stderr: stderr + "nothing was delivered\n", failed: true) }
            return MessageOutput(stdout: "delivered: \(delivered.joined(separator: ", "))\n", stderr: stderr)
        }
    }

    struct Read: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Read the Elis assistant chat transcript.")

        @Option(name: .long, help: "Return only the last N entries.")
        var last: Int?
        @OptionGroup var options: BasicOptions

        func validate() throws {
            if let last, last < 1 { throw ValidationError("--last must be a positive integer") }
        }

        func makeRequest() -> ControlRequest {
            guard let last else { return ControlRequest(cmd: .assistantRead) }
            var args = ControlArgs()
            args.last = last
            return ControlRequest(cmd: .assistantRead, args: args)
        }

        func run() throws {
            let reply = try SocketClient(path: options.socketPath()).send(makeRequest())
            try Msg.emit(Self.output(reply, json: options.json))
        }

        static func output(_ reply: SocketReply, json: Bool, timeZone: TimeZone = .current) -> MessageOutput {
            guard reply.response.ok else { return Msg.refused(reply, json: json) }
            if json { return MessageOutput(stdout: reply.line + "\n") }
            let entries = reply.response.result?.assistant?.entries ?? []
            guard !entries.isEmpty else { return MessageOutput() }
            let lines = entries.map { Assistant.formatEntry($0, timeZone: timeZone) }.joined(separator: "\n")
            return MessageOutput(stdout: lines + "\n")
        }
    }

    struct Provider: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Read or select the Elis assistant provider.")

        @Argument(help: "Provider name to select; omit to show the current provider and available choices.")
        var name: String?
        @OptionGroup var options: BasicOptions

        func makeRequest() -> ControlRequest {
            guard let name else { return ControlRequest(cmd: .assistantProvider) }
            var args = ControlArgs()
            args.provider = name
            return ControlRequest(cmd: .assistantProvider, args: args)
        }

        func run() throws {
            let reply = try SocketClient(path: options.socketPath()).send(makeRequest())
            try Msg.emit(Self.output(reply, json: options.json))
        }

        static func output(_ reply: SocketReply, json: Bool) -> MessageOutput {
            guard reply.response.ok else { return Msg.refused(reply, json: json) }
            if json { return MessageOutput(stdout: reply.line + "\n") }
            let result = reply.response.result?.assistant
            var lines = ["current: \(result?.provider ?? "none")"]
            if let providers = result?.providers, !providers.isEmpty {
                lines.append("available: \(providers.joined(separator: ", "))")
            }
            return MessageOutput(stdout: lines.joined(separator: "\n") + "\n")
        }
    }

    struct Show: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Show the Elis assistant chat.")
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .assistantShow, args: options.withWindow())
        }
    }
}

/// Reply is `elisctl reply`: send a session's reply back into the Elis assistant chat.
struct Reply: ParsableCommand, ConnectedCommand {
    static let configuration = CommandConfiguration(
        abstract: "Reply to the Elis assistant from inside an Elis session."
    )

    @Argument(help: "Reply text; use --stdin to read it instead.")
    var text: String?
    @Flag(name: .long, help: "Read the reply from stdin.")
    var stdin = false
    @OptionGroup var options: BasicOptions

    var connection: any ConnectionOptions { options }

    static let outsideSession = "elisctl reply runs inside an Elis session"

    func validate() throws {
        guard (text != nil) != stdin else { throw ValidationError("provide the reply as TEXT or --stdin, exactly one") }
    }

    func makeRequest(body: String) throws -> ControlRequest {
        guard let session = CallerEnvironment.ownSession else {
            throw SocketClientError(Self.outsideSession)
        }
        return ControlRequest(cmd: .assistantReply, target: session, args: ControlArgs(text: body))
    }

    func run() throws {
        guard CallerEnvironment.ownSession != nil else {
            throw SocketClientError(Self.outsideSession)
        }
        let body = try text ?? decodeTypedStdin(FileHandle.standardInput.readDataToEndOfFile())
        let reply = try SocketClient(path: options.socketPath()).send(makeRequest(body: body))
        try Msg.emit(Self.output(reply, json: options.json))
    }

    static func output(_ reply: SocketReply, json: Bool) -> MessageOutput {
        guard reply.response.ok else { return Msg.refused(reply, json: json) }
        if json { return MessageOutput(stdout: reply.line + "\n") }
        return MessageOutput(stdout: "ok\n")
    }
}
