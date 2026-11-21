import ElisCore
import Foundation
#if canImport(Glibc)
import Glibc
#endif

// Every call takes and returns UTF-8 JSON; the caller frees each result with elis_free.

private func reply(_ response: ControlResponse) -> UnsafeMutablePointer<CChar>? {
    let data = (try? JSONEncoder().encode(response)) ?? Data(#"{"ok":false,"error":"encoding failed"}"#.utf8)
    return strdup(String(decoding: data, as: UTF8.self))
}

private func arguments(_ argsJSON: UnsafePointer<CChar>) -> Result<ClaudeTranscriptArguments, ControlResponse> {
    let text = String(cString: argsJSON)
    let args: ControlArgs?
    do {
        args = text.isEmpty || text == "null" ? nil : try JSONDecoder().decode(ControlArgs.self, from: Data(text.utf8))
    } catch {
        return .failure(ControlResponse(ok: false, error: "invalid arguments"))
    }
    return ControlDispatcher.transcriptArguments(args)
}

/// `session.transcript` argument check, run before the host resolves the target: `{"ok":true,"result":{"pane":…}}`
/// with the requested pane (absent for the agent's pane) or the refusal the Mac answers.
@_cdecl("elis_transcript_arguments")
public func elisTranscriptArguments(_ argsJSON: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    switch arguments(argsJSON) {
    case .failure(let refusal): return reply(refusal)
    case .success(let parsed):
        var result = ControlResult()
        result.pane = parsed.pane?.rawValue
        return reply(ControlResponse(ok: true, result: result))
    }
}

/// One `session.transcript` page of the Claude session `sessionID` under `claudeDirectory`; blocks on file reads.
@_cdecl("elis_transcript_read")
public func elisTranscriptRead(_ argsJSON: UnsafePointer<CChar>, _ claudeDirectory: UnsafePointer<CChar>,
                               _ sessionID: UnsafePointer<CChar>, _ pane: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    switch arguments(argsJSON) {
    case .failure(let refusal): return reply(refusal)
    case .success(let parsed):
        let source = ControlTranscriptSource(claudeSessionID: String(cString: sessionID),
                                             pane: StatusPane(rawValue: String(cString: pane)) ?? .left,
                                             claudeDirectory: String(cString: claudeDirectory))
        return reply(ControlDispatcher.transcriptResponse(source, parsed))
    }
}

@_cdecl("elis_free")
public func elisFree(_ pointer: UnsafeMutablePointer<CChar>?) { free(pointer) }
