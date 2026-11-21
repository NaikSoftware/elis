import ElisCore
import Foundation

private struct Tinted: Encodable {
    var ok = true
    let tint: String?
}

/// A row tint checked by the Mac's parse. Placements are checked as the Mac checks them, then dropped: a tint colors
/// every part.
@_cdecl("elis_tint_parse")
public func elisTintParse(_ command: UnsafePointer<CChar>, _ argsJSON: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    let command = String(cString: command)
    guard let args = try? JSONDecoder().decode(ControlArgs.self, from: Data(String(cString: argsJSON).utf8)) else {
        return encoded(Refusal(error: "invalid arguments"))
    }
    let tint: Result<TintValue?, TintRejection> = command.hasSuffix(".tint")
        ? ControlDispatcher.tintUpdate(args, command: command).map {
            if case let .set(color, _) = $0 { color } else { nil }
        }
        : ControlDispatcher.creationTint(args).map { $0?.color }
    switch tint {
    case .failure(let rejection): return encoded(Refusal(error: rejection.message))
    case .success(let value): return encoded(Tinted(tint: value?.rawValue))
    }
}

@_cdecl("elis_tint_palette")
public func elisTintPalette() -> UnsafeMutablePointer<CChar>? {
    struct Color: Encodable {
        let name: String
        let light: String
        let dark: String
    }
    struct Palette: Encodable {
        let colors: [Color]
        let shownParts: [String]
    }
    let hex = { (rgb: UInt32) in "#" + String(format: "%06x", rgb) }
    return encoded(Palette(colors: TintColor.allCases.map {
        Color(name: $0.rawValue, light: hex($0.rgb(dark: false)), dark: hex($0.rgb(dark: true)))
    }, shownParts: SidebarTint.shownParts))
}
