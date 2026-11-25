import ElisCore
import XCTest
@testable import Elis

@MainActor
final class AssistantRunnerTests: XCTestCase {
    private static let fake = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("linux/tests/fixtures/fake-provider.sh").path
    private var stateDir: URL!
    private var chat: AssistantChat!
    private var runners: [AssistantRunner] = []

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory.appendingPathComponent("elis-assistant-\(UUID().uuidString)")
        chat = AssistantChat()
    }

    override func tearDown() async throws {
        runners.forEach { $0.stopForQuit() }
        runners = []
        try? FileManager.default.removeItem(at: stateDir)
        try await super.tearDown()
    }

    private func runner(standIn: [String]? = nil, stateDirectory: URL?? = nil, base: [String: String]? = nil,
                        appPid: pid_t = getpid(), now: @escaping () -> Date = Date.init) -> AssistantRunner {
        let runner = AssistantRunner(chat: chat, stateDirectory: stateDirectory ?? stateDir, standIn: standIn ?? ["/bin/bash", Self.fake],
                                     baseEnvironment: base ?? ProcessInfo.processInfo.environment, appPid: appPid, now: now)
        runners.append(runner)
        return runner
    }

    private func ask(_ runner: AssistantRunner, _ text: String) {
        chat.append(.user, text: text, now: 0)
        chat.inputQueued()
        runner.enqueue(text)
    }

    private func entries(_ kind: AssistantEntry.Kind) -> [String] {
        chat.entries(last: nil).filter { $0.kind == kind }.map(\.text)
    }

    private func waitFor(_ what: String, seconds: TimeInterval = 30, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "timed out waiting for \(what)")
    }

    private func pid(of answer: String) -> String? {
        answer.split(separator: ":").first.map(String.init)
    }

    func testTwoQueuedAsksRunAsTwoTurnsInOrder() async {
        let runner = runner()
        ask(runner, "a")
        ask(runner, "b")
        await waitFor("two answers") { entries(.assistant).count == 2 && !chat.running }
        let answers = entries(.assistant)
        let pid = answers.first.flatMap(pid(of:)) ?? ""
        XCTAssertEqual(answers.map { $0.replacingOccurrences(of: " leaked", with: "") }, ["\(pid): a", "\(pid): b"])
        XCTAssertFalse(chat.running)
    }

    func testFakeMarksAnEarlyLine() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.fake]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data("{\"text\":\"a\"}\n{\"text\":\"b\"}\n".utf8))
        try input.fileHandleForWriting.close()
        await waitFor("the fake to exit") { !process.isRunning }
        if process.isRunning { process.terminate() }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let answers = text.split(separator: "\n").flatMap { AssistantStream.decode(.claude, line: String($0)) }
            .compactMap { if case let .text(text) = $0 { text } else { nil } }
        XCTAssertTrue(answers.first?.replacingOccurrences(of: " leaked", with: "").hasSuffix(" early") == true, "\(answers)")
    }

    func testSecondInputWaitsForTheTurnEnd() async {
        let runner = runner()
        ask(runner, "a")
        ask(runner, "r")
        await waitFor("two answers") { entries(.assistant).count == 2 }
        XCTAssertFalse(entries(.assistant).contains { $0.replacingOccurrences(of: " leaked", with: "").hasSuffix(" early") })
    }

    func testEnvironmentScrubsElisAndClaudeMarkers() async throws {
        let environment = AssistantRunner.environment(
            base: ["ELIS_SESSION_ID": "x", "CLAUDECODE": "1", "CLAUDE_CONFIG_DIR": "/c", "HOME": "/h"],
            stateDirectory: "/s", path: "/p", launch: ["K": "v"]
        )
        XCTAssertEqual(environment, ["CLAUDE_CONFIG_DIR": "/c", "HOME": "/h", "ELIS_STATE_DIR": "/s", "PATH": "/p", "K": "v"])

        var base = ProcessInfo.processInfo.environment
        base["ELIS_SESSION_ID"] = "x"
        base["CLAUDECODE"] = "1"
        let runner = runner(base: base)
        ask(runner, "env")
        await waitFor("the env answer") { entries(.assistant).count == 1 }
        let answer = try XCTUnwrap(entries(.assistant).first)
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS").path
        XCTAssertTrue(answer.hasPrefix("\(stateDir.path) \(bundled):"), answer)
        ask(runner, "a")
        await waitFor("the plain answer") { entries(.assistant).count == 2 }
        let plain = try XCTUnwrap(entries(.assistant).last)
        XCTAssertTrue(plain.hasSuffix(": a"), plain)
    }

    func testMissingBinaryYieldsOneErrorAndStopsRunning() async {
        let runner = runner(standIn: ["/nonexistent/elis-fake-provider"])
        ask(runner, "a")
        await waitFor("the error") { !entries(.error).isEmpty }
        XCTAssertEqual(entries(.error).count, 1)
        XCTAssertFalse(chat.running)
    }

    func testCrashMidTurnYieldsOneErrorAndNextInputRestarts() async throws {
        let runner = runner()
        ask(runner, "a")
        await waitFor("the first answer") { entries(.assistant).count == 1 }
        ask(runner, "crash")
        await waitFor("the crash error") { entries(.error).count == 1 }
        XCTAssertEqual(entries(.error).count, 1)
        ask(runner, "x")
        await waitFor("the answer after the crash") { entries(.assistant).count == 2 }
        let answers = entries(.assistant)
        XCTAssertEqual(answers.count, 2)
        XCTAssertNotEqual(answers.first.flatMap(pid(of:)), answers.last.flatMap(pid(of:)))
        XCTAssertTrue(answers.last?.contains(": x") == true, "\(answers)")
    }

    func testGoneResumeRetriesFreshWithTheChatInlined() async throws {
        chat.append(.user, text: "earlier-marker", now: 0)
        chat.resume[.claude] = "gone"
        let runner = runner()
        ask(runner, "x")
        await waitFor("the retried answer") { entries(.assistant).count == 1 && !chat.running }
        XCTAssertEqual(entries(.error), [])
        XCTAssertNotEqual(chat.resume[.claude], "gone")
        let answer = try XCTUnwrap(entries(.assistant).first)
        XCTAssertTrue(answer.contains("user: earlier-marker"), answer)
    }

    func testStreamProviderAfterASwitchGetsTheRecap() async throws {
        chat.provider = .codex
        let runner = runner()
        ask(runner, "first-turn-marker")
        await waitFor("the codex answer") { entries(.assistant).count == 1 && !chat.running }
        chat.provider = .claude
        runner.providerChanged(.claude)
        ask(runner, "second")
        await waitFor("the claude answer") { entries(.assistant).count == 2 }
        let answer = try XCTUnwrap(entries(.assistant).last)
        XCTAssertTrue(answer.contains("user: first-turn-marker"), answer)
    }

    func testProviderChangeRestartsWithTheRecap() async throws {
        let runner = runner()
        ask(runner, "first-turn-marker")
        await waitFor("the first answer") { entries(.assistant).count == 1 && !chat.running }
        chat.provider = .codex
        runner.providerChanged(.codex)
        ask(runner, "second")
        await waitFor("the codex answer") { entries(.assistant).count == 2 }
        let answer = try XCTUnwrap(entries(.assistant).last)
        XCTAssertTrue(answer.contains("user: first-turn-marker"), answer)
        XCTAssertTrue(answer.hasSuffix("second") || answer.hasSuffix("second leaked"), answer)
    }

    func testWatchdogFailsASilentTurn() async throws {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let runner = runner(standIn: ["/bin/bash", "-c", "exec sleep 600"], now: { clock })
        ask(runner, "quiet-forever")
        let pid = try XCTUnwrap(runner.pid)
        clock += 599
        runner.checkWatchdog()
        XCTAssertEqual(entries(.error), [])
        clock += 2
        runner.checkWatchdog()
        XCTAssertEqual(entries(.error), ["the assistant stopped responding"])
        XCTAssertFalse(chat.running)
        await waitFor("the silent provider to exit", seconds: 5) { kill(pid, 0) != 0 }
    }

    func testClearAndQuitLeaveNoChild() async throws {
        let runner = runner()
        ask(runner, "a")
        await waitFor("the answer") { entries(.assistant).count == 1 }
        let first = try XCTUnwrap(runner.pid)
        let pidfile = stateDir.appendingPathComponent("assistant/provider.pid")
        XCTAssertEqual(try String(contentsOf: pidfile, encoding: .utf8), "\(first) \(try XCTUnwrap(AssistantRunner.startTime(first)))\n")
        runner.clear()
        await waitFor("the cleared provider to exit", seconds: 5) { kill(first, 0) != 0 }

        ask(runner, "b")
        await waitFor("the second answer") { entries(.assistant).count == 2 }
        let second = try XCTUnwrap(runner.pid)
        runner.stopForQuit()
        await waitFor("the quit provider to exit", seconds: 5) { kill(second, 0) != 0 }
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidfile.path))
    }

    func testStalePidfileProcessIsTerminatedOnLaunch() async throws {
        let pidfile = stateDir.appendingPathComponent("assistant/provider.pid")
        try FileManager.default.createDirectory(at: pidfile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stale = try sleeper(), reused = try sleeper()
        defer { [stale, reused].forEach { $0.terminate() } }

        try "\(reused.processIdentifier) 1.0\n".write(to: pidfile, atomically: true, encoding: .utf8)
        _ = AssistantModel(stateDirectory: stateDir, standIn: nil)
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(reused.isRunning)

        let started = try XCTUnwrap(AssistantRunner.startTime(stale.processIdentifier))
        try "\(stale.processIdentifier) \(started)\n".write(to: pidfile, atomically: true, encoding: .utf8)
        _ = AssistantModel(stateDirectory: stateDir, standIn: nil)
        await waitFor("the stale provider to exit", seconds: 5) { !stale.isRunning }
    }

    func testProviderEndsWhenTheAppDies() async throws {
        let app = try sleeper()
        defer { app.terminate() }
        let runner = runner(standIn: ["/bin/bash", "-c", "exec sleep 600"], appPid: app.processIdentifier)
        ask(runner, "a")
        let provider = try XCTUnwrap(runner.pid)
        let guardian = try XCTUnwrap(runner.guardian)
        XCTAssertTrue(guardian.isRunning)

        app.terminate()
        await waitFor("the provider to exit", seconds: 5) { kill(provider, 0) != 0 }
        await waitFor("the guard to exit", seconds: 5) { !guardian.isRunning }
    }

    func testGuardEndsWithItsProvider() async throws {
        let runner = runner(standIn: ["/bin/bash", "-c", "exec sleep 600"])
        ask(runner, "a")
        let guardian = try XCTUnwrap(runner.guardian)
        runner.stopForQuit()
        await waitFor("the guard to exit", seconds: 5) { !guardian.isRunning }
    }

    private func sleeper() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["600"]
        try process.run()
        return process
    }

    func testNoStateDirectoryRefusesToSpawn() async {
        let runner = runner(stateDirectory: .some(nil))
        ask(runner, "a")
        XCTAssertEqual(entries(.error), ["the assistant is off in this instance"])
        XCTAssertNil(runner.pid)
        XCTAssertFalse(chat.running)
    }
}
