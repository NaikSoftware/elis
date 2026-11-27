import ElisCore
import Foundation

// The saved browser store of --persistent pages (BrowserProfile) and `browser.*`'s checks, as the Mac's
// ControlDispatcher+Browser and HtmlOverlayRegistry decide them.

private struct BrowserRequest: Decodable {
    var target: String?
    var window: String?
    var mode: String?
    var current: String?
    var directory: String?
    var openPages: Int?
    var clearing: Bool?
}

private struct ProfileID: Encodable {
    var ok = true
    let id: String?
}

private func request(_ json: UnsafePointer<CChar>) -> BrowserRequest? {
    try? JSONDecoder().decode(BrowserRequest.self, from: Data(String(cString: json).utf8))
}

// app-global: one store and one setting serve every window
private func scopeRefusal(_ request: BrowserRequest, _ cmd: String) -> UnsafeMutablePointer<CChar>? {
    guard request.target?.isEmpty == false || request.window != nil else { return nil }
    return encoded(Refusal(error: "\(cmd) takes no target or --window"))
}

/// The profile id of `directory`, created when its file is missing: {"ok":true,"id"}, or {"ok":false,"error"} for
/// an unreadable or malformed file, which is left alone. Input {"directory","clearing"?}: a store being cleared refuses.
@_cdecl("elis_browser_profile")
public func elisBrowserProfile(_ json: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    guard let request = request(json), let directory = request.directory else { return encoded(Refusal(error: OverlayHtmlError.persistentUnavailable)) }
    if request.clearing == true { return encoded(Refusal(error: BrowserClearError.clearing)) }
    do {
        return encoded(ProfileID(id: try BrowserProfile(directory: URL(fileURLWithPath: directory)).identifier().uuidString))
    } catch {
        return encoded(Refusal(error: String(describing: error)))
    }
}

/// `browser.clear`'s decision: {"ok":true,"id"} names the store to empty, a null id meaning no profile exists and
/// nothing is created; or the Mac's refusal. Input {"target"?,"window"?,"directory","openPages","clearing"?}.
@_cdecl("elis_browser_clear")
public func elisBrowserClear(_ json: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    guard let request = request(json), let directory = request.directory else { return encoded(Refusal(error: "invalid arguments")) }
    if let refusal = scopeRefusal(request, "browser.clear") { return refusal }
    if request.clearing == true { return encoded(Refusal(error: "browser.clear: \(BrowserClearError.clearing)")) }
    if let open = request.openPages, open > 0 { return encoded(Refusal(error: "browser.clear: \(BrowserClearError.pagesOpen(open))")) }
    do {
        return encoded(ProfileID(id: try BrowserProfile(directory: URL(fileURLWithPath: directory)).existingIdentifier()?.uuidString))
    } catch {
        return encoded(Refusal(error: "browser.clear: \(error)"))
    }
}

/// `browser.links`: {"ok":true,"mode"} with the effective mode after the request, from {"target"?,"window"?,"mode"?,
/// "current"}; an absent mode reads.
@_cdecl("elis_browser_links")
public func elisBrowserLinks(_ json: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    struct Mode: Encodable {
        var ok = true
        let mode: String
    }
    guard let request = request(json) else { return encoded(Refusal(error: "invalid arguments")) }
    if let refusal = scopeRefusal(request, "browser.links") { return refusal }
    guard let raw = request.mode else {
        return encoded(Mode(mode: AppSettings(linkOpenMode: request.current).effectiveLinkOpenMode.rawValue))
    }
    guard let mode = LinkOpenMode(rawValue: raw) else { return encoded(Refusal(error: "invalid link mode: \(raw)")) }
    return encoded(Mode(mode: mode.rawValue))
}
