import ElisCore
import Foundation

private struct Parsed: Encodable {
    let progress: SessionProgress?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(true, forKey: .ok)
        try container.encode(progress, forKey: .progress) // an explicit null means "clear"
    }

    private enum Keys: String, CodingKey { case ok, progress }
}

/// `session.progress` text (`3/7`, `40%`, `indeterminate`, `clear`) checked by the Mac's parse:
/// `{"ok":true,"progress":{…}|null}` (null clears), else `{"ok":false,"error":"invalid progress"}`.
@_cdecl("elis_progress_parse")
public func elisProgressParse(_ text: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    do {
        return encoded(Parsed(progress: try SessionProgress.parse(String(cString: text))))
    } catch {
        return encoded(Refusal(error: "\(error)"))
    }
}

/// An OSC 9 body such as `4;1;40`: `{"update":"clear"}`, `{"update":"set","progress":{…}}`, or `null` when it is no progress.
@_cdecl("elis_progress_terminal")
public func elisProgressTerminal(_ body: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    struct Update: Encodable {
        let update: String
        var progress: SessionProgress?
    }
    switch SessionProgress.conEmu(String(cString: body)) {
    case nil: return strdup("null")
    case .clear?: return encoded(Update(update: "clear"))
    case .set(let progress)?: return encoded(Update(update: "set", progress: progress))
    }
}

/// A row's progress fill and wave, from `{"progress"?,"status","sessionTint"?,"workspaceTint"?,"active"}`:
/// `{"fill":{"color","fraction","alpha","feather"}|null,"wave":bool}`; null for an input that does not decode.
@_cdecl("elis_progress_row")
public func elisProgressRow(_ json: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    struct Input: Decodable {
        let progress: SessionProgress?
        let status: AgentStatus
        let sessionTint: String?
        let workspaceTint: String?
        let active: String
    }
    struct Fill: Encodable {
        let color: String
        let fraction: Double
        let alpha = SidebarProgressFill.alpha
        let feather = SidebarProgressFill.feather
    }
    struct Row: Encodable {
        let fill: Fill?
        let wave: Bool

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Keys.self)
            try container.encode(fill, forKey: .fill)
            try container.encode(wave, forKey: .wave)
        }

        private enum Keys: String, CodingKey { case fill, wave }
    }
    guard let input = try? JSONDecoder().decode(Input.self, from: Data(String(cString: json).utf8)) else {
        return strdup("null")
    }
    let fill = SidebarBand.progressFill(progress: input.progress, status: input.status, sessionTintHex: input.sessionTint,
                                        workspaceTintHex: input.workspaceTint, activeHex: input.active)
    // The accent only colors the wave, never whether it shows, and the Linux row needs only the boolean.
    let wave = SidebarBand.wave(status: input.status, indeterminate: input.progress == .indeterminate,
                                sessionTintHex: input.sessionTint, workspaceTintHex: input.workspaceTint,
                                activeHex: input.active, accentHex: input.active)
    return encoded(Row(fill: fill.map { Fill(color: $0.colorHex, fraction: $0.fraction) }, wave: wave != nil))
}
