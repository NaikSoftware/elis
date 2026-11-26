import ArgumentParser
import Foundation
import Testing
import ElisCore
@testable import elisctlKit

@Suite(.outsidePane)
struct SessionUploadCommandTests {
    private func run(size: Int, input: [UInt8], answer: ControlUpload) throws -> (ControlResponse, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let reserved = dir.appendingPathComponent("f.txt")
        FileManager.default.createFile(atPath: reserved.path, contents: nil)
        var upload = answer
        if upload.host == nil { upload.path = reserved.path }
        var result = ControlResult()
        result.upload = upload
        let server = StubServer(response: ControlResponse(ok: true, result: result))
        try server.start()
        defer { server.stop() }
        let command = try #require(try Elisctl.parseAsRoot(["session", "upload", "--target", "s1", "--name", "f.txt", "--size", "\(size)"])
            as? elisctlKit.Session.Upload)
        var rest = input[...]
        let response = command.execute(client: SocketClient(path: server.path)) { count in
            defer { rest = rest.dropFirst(count) }
            return Data(rest.prefix(count))
        }
        return (response, dir)
    }

    @Test func fiveBytesLandAtTheReservedPath() throws {
        let (response, dir) = try run(size: 5, input: Array("hello".utf8), answer: ControlUpload())
        #expect(response.ok)
        let path = try #require(response.result?.upload?.path)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "hello")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["f.txt"])
    }

    @Test func aShortStreamFailsAndLeavesNoFile() throws {
        let (response, dir) = try run(size: 5, input: [1, 2, 3], answer: ControlUpload())
        #expect(!response.ok)
        #expect(response.error == "upload ended after 3 of 5 bytes")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func aLongStreamFailsAndLeavesNoFile() throws {
        let (response, dir) = try run(size: 5, input: [1, 2, 3, 4, 5, 6], answer: ControlUpload())
        #expect(response.error == "file changed while sending")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func aRemoteAnswerIsRefused() throws {
        let (response, dir) = try run(size: 1, input: [1], answer: ControlUpload(host: "h", session: "s"))
        #expect(response.error == "cannot upload to a remote row from here")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["f.txt"])
    }
}
