import ElisCore
import Foundation
import Testing

struct AntigravityStatusHookTests {
    private static let agentStatus = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("agent-status")

    private func run(_ action: String, input: String = "{}", environment extra: [String: String] = [:]) throws
        -> (stdout: String, statuses: [String]) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("elis-agy-hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let statuses = dir.appendingPathComponent("statuses")
        let wrapper = dir.appendingPathComponent("wrapper")
        try "#!/bin/bash\nprintf '%s\\n' \"$*\" >> '\(statuses.path)'\n".writeExecutable(to: wrapper)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [Self.agentStatus.appendingPathComponent("elis-antigravity-status.sh").path, action]
        proc.environment = ["ELIS_STATUS_WRAPPER": wrapper.path, "ELIS_SESSION_ID": "sid", "PATH": "/usr/bin:/bin"]
            .merging(extra) { $1 }.filter { !$0.value.isEmpty }
        let stdin = Pipe(), stdout = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        try proc.run()
        try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        proc.waitUntilExit()
        #expect(proc.terminationStatus == 0)
        let calls = ((try? String(contentsOf: statuses, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        return (output, calls)
    }

    @Test(arguments: [
        ("invocation", "active --blink"),
        ("tool-done", "active --blink"),
        ("ask", "blocked"),
        ("stop", "completed --auto-reset"),
    ])
    func actionReportsItsState(action: String, state: String) throws {
        let result = try run(action)
        #expect(result.stdout.isEmpty) // agy denies a tool whose PreToolUse prints `{}`
        #expect(result.statuses == [state])
    }

    @Test func stopWithBackgroundWorkLeavesTheRowActive() throws {
        #expect(try run("stop", input: #"{"fullyIdle": false}"#).statuses.isEmpty)
        #expect(try run("stop", input: #"{"fullyIdle":true}"#).statuses == ["completed --auto-reset"])
    }

    @Test(arguments: [["ELIS_SESSION_ID": ""], ["CLAUDECODE": "1"], ["CLAUDE_CODE_SESSION_ID": "c"]])
    func outsideAnOwnedPaneItStaysSilent(environment: [String: String]) throws {
        let result = try run("invocation", environment: environment)
        #expect(result.stdout.isEmpty)
        #expect(result.statuses.isEmpty)
    }

    @Test func pluginHooksCallTheInstalledAdapterWithKnownActions() throws {
        let hooks = try String(contentsOf: Self.agentStatus.appendingPathComponent("antigravity/hooks.json"), encoding: .utf8)
        let root = try #require(JSONSerialization.jsonObject(with: Data(hooks.utf8)) as? [String: Any])
        #expect(Array(root.keys) == ["elis-status"])
        let commands = hooks.split(separator: "\n").filter { $0.contains("\"command\":") }
        #expect(commands.count == 4)
        for command in commands {
            #expect(command.contains("$HOME/.config/elis/agent-status/elis-antigravity-status.sh"))
            #expect(command.hasSuffix("|| true\",")) // a failing hook command makes agy deny the tool
        }
        let plugin = try String(contentsOf: Self.agentStatus.appendingPathComponent("antigravity/plugin.json"), encoding: .utf8)
        #expect(plugin.contains(AgentHooksInstall.antigravityPluginMarker))
    }
}
