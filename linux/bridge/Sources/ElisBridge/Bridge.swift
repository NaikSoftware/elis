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

/// One `session.transcript` page of `agent`'s conversation `sessionID` under `directory`; blocks on file reads.
@_cdecl("elis_transcript_read")
public func elisTranscriptRead(_ argsJSON: UnsafePointer<CChar>, _ agent: UnsafePointer<CChar>, _ directory: UnsafePointer<CChar>,
                               _ sessionID: UnsafePointer<CChar>, _ pane: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    switch arguments(argsJSON) {
    case .failure(let refusal): return reply(refusal)
    case .success(let parsed):
        let source = ControlTranscriptSource(claudeSessionID: String(cString: sessionID),
                                             pane: StatusPane(rawValue: String(cString: pane)) ?? .left,
                                             claudeDirectory: String(cString: directory),
                                             agent: SessionLauncher(rawValue: String(cString: agent)) ?? .claude)
        return reply(ControlDispatcher.transcriptResponse(source, parsed))
    }
}

func encoded<T: Encodable>(_ value: T) -> UnsafeMutablePointer<CChar>? {
    let data = (try? JSONEncoder().encode(value)) ?? Data(#"{"ok":false,"error":"encoding failed"}"#.utf8)
    return strdup(String(decoding: data, as: UTF8.self))
}

struct Refusal: Encodable {
    var ok = false
    let error: String
}

/// `sidebar.density`'s mode against the current density: `{"ok":true,"density":"default|compact"}` or the Mac's
/// refusal. Input `{"mode"?,"current"}`; an absent mode toggles.
@_cdecl("elis_sidebar_density")
public func elisSidebarDensity(_ json: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    struct Input: Decodable {
        let mode: String?
        let current: String
    }
    struct Density: Encodable {
        var ok = true
        let density: String
    }
    guard let input = try? JSONDecoder().decode(Input.self, from: Data(String(cString: json).utf8)) else {
        return encoded(Refusal(error: "invalid arguments"))
    }
    let current = SidebarDensity(rawValue: input.current) ?? .standard
    switch ControlSidebarDensityMode.parse(input.mode) {
    case nil: return encoded(Refusal(error: "invalid sidebar density: \(input.mode ?? "toggle")"))
    case .standard: return encoded(Density(density: SidebarDensity.standard.rawValue))
    case .compact: return encoded(Density(density: SidebarDensity.compact.rawValue))
    case .toggle: return encoded(Density(density: (current == .compact ? SidebarDensity.standard : .compact).rawValue))
    }
}

@_cdecl("elis_free")
public func elisFree(_ pointer: UnsafeMutablePointer<CChar>?) { free(pointer) }
