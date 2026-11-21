import Foundation
import Testing
@testable import ElisCore

struct ZmxPlainShellTests {
    @Test func eachShellRunsTheLineQuotedForIt() {
        let line = "printf '%s\\n' \"it's\""
        #expect(ZmxReplayScript.plainShellArguments(commandLine: line, shell: "/bin/zsh") == ["/bin/zsh", "-lic",
            "{ 'builtin' 'eval' -- 'printf '\\''%s\\n'\\'' \"it'\\''s\"' ; } always { builtin exec -- '/bin/zsh' -il ; }"])
        #expect(ZmxReplayScript.plainShellArguments(commandLine: "top", shell: "/usr/bin/fish") == ["/usr/bin/fish", "-lic",
            "builtin status job-control full; builtin eval 'top'; exec '/usr/bin/fish' -il"])
        #expect(ZmxReplayScript.plainShellArguments(commandLine: "top", shell: "/bin/tcsh")
            == ["/bin/sh", "-c", "trap 'exec \"$1\" -l' EXIT; eval \"$0\"", "top", "/bin/tcsh"])
    }

    @Test(arguments: ["/bin/bash", "/bin/sh", "/usr/bin/fish", "/bin/zsh"])
    func theLineRunsThenTheLoginShellTakesOver(shell: String) throws {
        guard FileManager.default.isExecutableFile(atPath: shell) else { return }
        let home = FileManager.default.temporaryDirectory.appending(path: "elis-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let argv = ZmxReplayScript.plainShellArguments(commandLine: "echo 'ran it'; false", shell: shell)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin", "XDG_CONFIG_HOME": home.path,
                               "XDG_DATA_HOME": home.path, "ZDOTDIR": home.path]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data("echo final\nexit\n".utf8))
        try input.fileHandleForWriting.close()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(text.contains("ran it\n") && text.contains("final\n"), "\(shell) printed \(text)")
    }
}
