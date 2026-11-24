import Foundation
import Testing
@testable import ElisCore

struct AntigravityTranscriptTests {
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agt-\(UUID().uuidString)")
        let id = "conv-1"
        var fileURL: URL {
            root.appendingPathComponent("brain/\(id)/.system_generated/logs/transcript_full.jsonl")
        }
        var path: String { fileURL.path }
        lazy var reader = AntigravityTranscript(directory: root.path)

        init(_ lines: [String] = []) throws {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: fileURL)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func append(_ text: String) throws {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        }

        func append(lines: [String]) throws { try append(lines.map { $0 + "\n" }.joined()) }

        func overwrite(lines: [String]) throws {
            try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: fileURL)
        }

        func page(after: Int? = nil, before: Int? = nil, held: String? = nil,
                  maxBytes: Int = ClaudeTranscript.pageBudget) throws -> ClaudeTranscriptPage {
            try reader.page(ClaudeTranscriptRequest(sessionID: id, after: after, before: before, held: held, maxBytes: maxBytes)).get()
        }

        var size: Int { (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? -1 }
    }

    private static func json(_ dict: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return String(decoding: data, as: UTF8.self)
    }

    private func row(step: Int, source: String, type: String, status: String = "DONE",
                     createdAt: String = "2026-11-24T00:00:00Z", content: String? = nil,
                     thinking: String? = nil, toolCalls: [[String: Any]]? = nil,
                     error: String? = nil, model: String? = nil) -> String {
        var dict: [String: Any] = [
            "step_index": step,
            "source": source,
            "type": type,
            "status": status,
            "created_at": createdAt,
        ]
        if let content { dict["content"] = content }
        if let thinking { dict["thinking"] = thinking }
        if let toolCalls { dict["tool_calls"] = toolCalls }
        if let error { dict["error"] = error }
        if let model { dict["model"] = model }
        return Self.json(dict)
    }

    private func user(_ step: Int, _ content: String) -> String {
        row(step: step, source: "USER_EXPLICIT", type: "USER_INPUT", content: content)
    }

    private func planner(_ step: Int, thinking: String? = nil, content: String? = nil,
                         toolCalls: [[String: Any]]? = nil, error: String? = nil,
                         model: String? = "gemini-4-neon-high") -> String {
        row(step: step, source: "MODEL", type: "PLANNER_RESPONSE", content: content,
            thinking: thinking, toolCalls: toolCalls, error: error, model: model)
    }

    private func toolResult(_ step: Int, type: String = "GENERIC", status: String = "DONE",
                            content: String? = nil, error: String? = nil) -> String {
        row(step: step, source: "MODEL", type: type, status: status, content: content, error: error)
    }

    private func encodedSize(_ items: [ControlTranscriptItem]) -> Int {
        (try? JSONEncoder().encode(items).count) ?? 0
    }

    @Test func tailPageExtractsUserThinkingTextToolAndModel() throws {
        let prompt = "<USER_REQUEST>\n  fix the bug \n</USER_REQUEST>\n<ADDITIONAL_METADATA>\nlocal time\n</ADDITIONAL_METADATA>\n<USER_SETTINGS_CHANGE>model</USER_SETTINGS_CHANGE>"
        let cmdOutput = "Created At: 2026-11-24T00:00:01Z\nCompleted At: 2026-11-24T00:00:02Z\nCommand exited with code 0.\n\nCommand output:\nall tests passed"
        let fixture = try Fixture([
            row(step: 0, source: "SYSTEM", type: "SYSTEM_MESSAGE", content: "hidden"),
            user(1, prompt),
            row(step: 2, source: "SYSTEM_SDK", type: "EPHEMERAL_MESSAGE", content: "ignored"),
            planner(3, thinking: "analyzing bug", content: "Let me run tests.",
                    toolCalls: [["name": "run_command", "args": ["CommandLine": "swift test", "toolSummary": "Run tests"]]],
                    model: "gemini-4-neon-high"),
            toolResult(4, content: cmdOutput),
            row(step: 5, source: "SYSTEM", type: "CHECKPOINT", content: "cp"),
            row(step: 6, source: "SYSTEM_SDK", type: "CONVERSATION_HISTORY", content: "hist"),
        ])

        let page = try fixture.page()
        #expect(page.transcript == fixture.id)
        #expect(page.size == fixture.size && page.next == fixture.size && !page.reset)
        #expect(page.meta.model == "gemini-4-neon-high")
        #expect(page.skipped == 0 && page.commands == nil && page.pending.isEmpty)
        #expect(page.items.map(\.kind) == ["user", "thinking", "text", "tool"])
        #expect(page.items.map(\.uuid) == ["1", "3#thinking", "3#text", "3#tool0"])
        #expect(page.start == page.items.first?.at)

        let userItem = page.items[0]
        #expect(userItem.text == "fix the bug" && userItem.promptSource == "typed")

        let thinkingItem = page.items[1]
        #expect(thinkingItem.text == nil)

        let textItem = page.items[2]
        #expect(textItem.text == "Let me run tests.")

        let toolItem = page.items[3]
        #expect(toolItem.id == "3.0" && toolItem.name == "run_command" && toolItem.arg == "Run tests")
        #expect(toolItem.mark == "ok" && toolItem.exitCode == 0 && toolItem.running == nil && toolItem.isError == nil)
        #expect(toolItem.output == "Command exited with code 0.\n\nCommand output:\nall tests passed")
    }

    @Test func pairingSkipsSystemRowsAcceptsTypedResultAndHandlesErrors() throws {
        let fixture = try Fixture([
            planner(1, toolCalls: [
                ["name": "run_command", "args": ["CommandLine": "false"]],
                ["name": "read_file", "args": ["Path": "/repo/missing.swift"]],
                ["name": "run_command", "args": ["CommandLine": "sleep 10"]],
            ]),
            row(step: 2, source: "SYSTEM", type: "SYSTEM_MESSAGE", content: "interleaved"),
            row(step: 3, source: "SYSTEM_SDK", type: "EPHEMERAL_MESSAGE", content: "also interleaved"),
            toolResult(4, type: "RUN_COMMAND", status: "DONE",
                       content: "Created At: T1\nCompleted At: T2\nCommand exited with code 2\nfailed"),
            toolResult(5, type: "GENERIC", status: "ERROR",
                       content: "Created At: T3\nCompleted At: T4\n", error: "file not found"),
            toolResult(6, type: "GENERIC", status: "RUNNING",
                       content: "Created At: T5\nstill going"),
        ])

        let page = try fixture.page()
        #expect(page.items.count == 3)

        let cmd = page.items[0]
        #expect(cmd.id == "1.0" && cmd.arg == "false" && cmd.exitCode == 2 && cmd.mark == "exit 2" && cmd.isError == nil)

        let failed = page.items[1]
        #expect(failed.id == "1.1" && failed.isError == true && failed.mark == "error" && failed.output == "file not found")
        #expect(failed.file == "/repo/missing.swift" && failed.arg == "missing.swift" && failed.readOnly == true)

        let inProgress = page.items[2]
        #expect(inProgress.id == "1.2" && inProgress.output == "still going" && inProgress.mark == nil && inProgress.running == nil)
    }

    @Test func unansweredCallIsRunningAtTailAndInterruptedAfterUserInput() throws {
        let fixture = try Fixture([
            user(0, "go"),
            planner(1, toolCalls: [["name": "run_command", "args": ["CommandLine": "long-job"]]]),
        ])

        let live = try fixture.page()
        let liveTool = try #require(live.items.last)
        #expect(liveTool.kind == "tool" && liveTool.running == true && liveTool.mark == "running")

        try fixture.append(lines: [user(2, "stop that")])
        let afterInterrupt = try fixture.page()
        let interrupted = try #require(afterInterrupt.items.first { $0.kind == "tool" })
        #expect(interrupted.running == nil && interrupted.mark == "interrupted")
        #expect(afterInterrupt.items.last?.kind == "user" && afterInterrupt.items.last?.text == "stop that")
    }

    @Test func afterPageReEmitsEarlierToolCallsBeforeOtherItems() throws {
        let fixture = try Fixture([
            user(0, "check files"),
            planner(1, toolCalls: [
                ["name": "read_file", "args": ["Path": "/a/one.swift"]],
                ["name": "read_file", "args": ["Path": "/a/two.swift"]],
            ]),
        ])

        let first = try fixture.page()
        let plannerOffset = try #require(first.items.last?.at)
        #expect(first.items.filter { $0.kind == "tool" }.allSatisfy { $0.running == true })

        try fixture.append(lines: [
            toolResult(2, content: "Created At: T1\nCompleted At: T2\nfirst body"),
            row(step: 3, source: "SYSTEM", type: "ERROR_MESSAGE", content: "mid warning"),
            toolResult(4, content: "Created At: T3\nCompleted At: T4\nsecond body"),
            planner(5, content: "All read."),
        ])

        let poll = try fixture.page(after: first.next)
        #expect(!poll.reset && poll.start == first.next && poll.next == fixture.size)
        #expect(poll.items.map(\.uuid) == ["1#tool0", "1#tool1", "3", "5#text"])
        #expect(poll.items[0].at == plannerOffset && poll.items[0].output == "first body" && poll.items[0].running == nil)
        #expect(poll.items[1].at == plannerOffset && poll.items[1].output == "second body" && poll.items[1].running == nil)
        #expect(poll.items[2].kind == "error" && poll.items[2].text == "mid warning")
        #expect(poll.items[3].text == "All read.")
    }

    @Test func unterminatedLastLineIsIgnoredUntilCompleted() throws {
        let fixture = try Fixture([user(0, "first")])
        let first = try fixture.page()
        let line = user(1, "second")
        try fixture.append(String(line.prefix(25)))

        let partial = try fixture.page(after: first.next)
        #expect(partial.items.isEmpty && partial.size == first.size && partial.next == first.next)

        try fixture.append(String(line.dropFirst(25)) + "\n")
        let completed = try fixture.page(after: partial.next)
        #expect(completed.items.map(\.uuid) == ["1"])
        #expect(completed.items.first?.text == "second")
        #expect(completed.size == fixture.size && completed.next == fixture.size)
        #expect(fixture.reader.scans == 1)
    }

    @Test func shrunkFileRebuildsAndResets() throws {
        let fixture = try Fixture([user(0, "one"), user(1, "two"), user(2, "three")])
        let first = try fixture.page()
        try fixture.overwrite(lines: [user(0, "fresh")])

        let poll = try fixture.page(after: first.next)
        #expect(poll.reset && poll.items.map(\.text) == ["fresh"] && poll.size == fixture.size)
        #expect(fixture.reader.scans == 2)
    }

    @Test func heldMismatchResetsAndInvalidOrMissingIDIsNotFound() throws {
        let fixture = try Fixture([user(0, "hello")])
        let resetPage = try fixture.page(after: 0, held: "different-id")
        #expect(resetPage.reset && resetPage.items.map(\.uuid) == ["0"])
        #expect(try !fixture.page(after: resetPage.next, held: fixture.id).reset)

        #expect(fixture.reader.page(ClaudeTranscriptRequest(sessionID: "missing")) == .failure(.notFound))
        #expect(fixture.reader.page(ClaudeTranscriptRequest(sessionID: "../escape")) == .failure(.notFound))
    }

    @Test func budgetLimitsTailPageAndBeforeWalksOlderRows() throws {
        let lines = (0..<20).map { user($0, "msg-\($0)-" + String(repeating: "a", count: 80)) }
        let fixture = try Fixture(lines)

        let budget = 450
        let tail = try fixture.page(maxBytes: budget)
        #expect(encodedSize(tail.items) <= budget)
        #expect(!tail.items.isEmpty && tail.items.count < 20)
        #expect(tail.items.last?.uuid == "19")
        #expect(tail.start == tail.items.first?.at && tail.next == fixture.size)

        var collected = tail.items.map(\.uuid)
        var cursor = tail.start
        var steps = 0
        while cursor > 0 && steps < 20 {
            let older = try fixture.page(before: cursor, maxBytes: budget)
            #expect(encodedSize(older.items) <= budget)
            #expect(older.next == cursor)
            #expect(older.items.allSatisfy { $0.at < cursor })
            collected = older.items.map(\.uuid) + collected
            cursor = older.start
            steps += 1
        }
        #expect(steps > 1)
        #expect(collected == (0..<20).map(String.init))
    }

    @Test func toolArgumentsFilesReadOnlyAndClipping() throws {
        let bigOutput = "Created At: T\n" + String(repeating: "x", count: ClaudeTranscript.clipBytes + 100)
        let fixture = try Fixture([
            user(0, "   "),
            planner(1, toolCalls: [
                ["name": "view_file", "args": ["AbsolutePath": "/a/b/View.swift"]],
                ["name": "edit_file", "args": ["Path": "/a/b/Edit.swift"]],
                ["name": "write_to_file", "args": ["TargetFile": "/a/b/New.swift", "Content": "hi"]],
                ["name": "grep_search", "args": ["Query": "needle", "SearchPath": "/a"]],
                ["name": "list_dir", "args": ["DirectoryPath": "/a/b/folder/"]],
                ["name": "search_web", "args": ["query": "swift testing"]],
                ["name": "invoke_subagent", "args": ["Prompt": "do work"]],
            ], error: "rate limited", model: "model-v1"),
            toolResult(2, content: bigOutput),
            planner(3, content: "ok", model: nil),
        ])

        let page = try fixture.page()
        // empty user prompt is skipped; planner 1 emits 7 tools + 1 error; planner 3 emits 1 text
        #expect(page.meta.model == "model-v1")
        let tools = page.items.filter { $0.kind == "tool" }
        #expect(tools.count == 7)

        #expect(tools[0].arg == "View.swift" && tools[0].file == "/a/b/View.swift" && tools[0].readOnly == true)
        #expect(tools[0].clipped == true && tools[0].output?.utf8.count == ClaudeTranscript.clipBytes)

        #expect(tools[1].arg == "Edit.swift" && tools[1].file == "/a/b/Edit.swift" && tools[1].readOnly == nil && tools[1].mark == "interrupted")
        #expect(tools[2].arg == "New.swift" && tools[2].file == "/a/b/New.swift" && tools[2].readOnly == nil)
        #expect(tools[3].arg == "needle" && tools[3].file == nil && tools[3].readOnly == true)
        #expect(tools[4].arg == "folder" && tools[4].file == nil && tools[4].readOnly == true)
        #expect(tools[5].arg == "swift testing" && tools[5].file == nil && tools[5].readOnly == true)
        #expect(tools[6].arg == nil && tools[6].file == nil && tools[6].readOnly == nil)

        let errorItem = try #require(page.items.first { $0.kind == "error" })
        #expect(errorItem.uuid == "1#error" && errorItem.text == "rate limited")
    }

    @Test func instanceIsSharedPerDirectory() {
        #expect(AntigravityTranscript.instance(directory: "/tmp/ag-a") === AntigravityTranscript.instance(directory: "/tmp/ag-a"))
        #expect(AntigravityTranscript.instance(directory: "/tmp/ag-a") !== AntigravityTranscript.instance(directory: "/tmp/ag-b"))
    }
}
