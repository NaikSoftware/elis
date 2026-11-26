import ArgumentParser
import Foundation
import ElisCore

extension Session {
    struct Upload: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Write exactly --size bytes from stdin to a path the host reserves for the session.",
            discussion: "Always prints one JSON response line: {\"ok\":true,\"result\":{\"upload\":{\"path\":...}}} or an error."
        )
        @Option(name: .long, help: "File name; reduced to letters, digits, dot, dash and underscore.") var name: String
        @Option(name: .long, help: "Exact byte count to read from stdin.") var size: Int
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            var args = ControlArgs(name: name)
            args.size = size
            return ControlRequest(cmd: .sessionUpload, target: target.target, args: options.withWindow(args))
        }

        func run() throws {
            let response = execute(client: SocketClient(path: options.socketPath())) { count in
                (try? FileHandle.standardInput.read(upToCount: count)) ?? Data()
            }
            print(String(decoding: try JSONEncoder().encode(response), as: UTF8.self))
            if !response.ok { throw ExitCode.failure }
        }

        /// `read` returns up to `count` bytes, empty at end of input.
        func execute(client: SocketClient, read: (Int) -> Data) -> ControlResponse {
            func fail(_ message: String) -> ControlResponse { ControlResponse(ok: false, error: message) }
            guard size >= 0, size <= UploadLimits.maxBytes else { return fail("file too large (max 20 MiB)") }
            let reserved: ControlUpload
            do {
                let reply = try client.send(try makeRequest())
                guard reply.response.ok else { return reply.response }
                guard let upload = reply.response.result?.upload else { return fail("host did not reserve an upload path") }
                reserved = upload
            } catch {
                return fail("\(error)")
            }
            guard let path = reserved.path else { return fail("cannot upload to a remote row from here") }
            do {
                let sink = try UploadSink(path: URL(fileURLWithPath: path))
                var written = 0
                while written < size {
                    let chunk = read(min(65_536, size - written))
                    if chunk.isEmpty {
                        sink.abandon()
                        return fail("upload ended after \(written) of \(size) bytes")
                    }
                    do { try sink.write(chunk) } catch { sink.abandon(); throw error }
                    written += chunk.count
                }
                if !read(1).isEmpty {
                    sink.abandon()
                    return fail("file changed while sending")
                }
                var result = ControlResult()
                result.upload = ControlUpload(path: try sink.finish().path)
                return ControlResponse(ok: true, result: result)
            } catch {
                return fail("could not write the upload: \(error.localizedDescription)")
            }
        }
    }
}
