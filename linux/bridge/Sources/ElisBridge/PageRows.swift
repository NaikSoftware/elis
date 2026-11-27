import ElisCore
import Foundation

// Page rows (session.page, session.companion.page): ElisCore's argument check, the PageSnapshot a row is saved as,
// PageSessionRefusal, and the LinkPolicy route of a clicked terminal link.

private struct RowFlags: Codable {
    var navigation = false
    var javascript = false
    var chromeless = false
    var persistent = false
    var browse = false
}

/// `session.page` (`{"page":true,"args"}`) or `session.companion.page`'s arguments: {"ok":true,"page":source,"flags",
/// "color"?,"follow"} or the Mac's refusal.
@_cdecl("elis_page_row_arguments")
public func elisPageRowArguments(_ json: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    struct Request: Decodable {
        let page: Bool
        var args: ControlArgs?
    }
    struct Checked: Encodable {
        var ok = true
        let page: PageSource
        let flags: RowFlags
        let color: String?
        let follow: Bool
    }
    guard let request = decode(Request.self, json) else { return encoded(Refusal(error: "invalid arguments")) }
    let checked = ControlDispatcher.pageRowCheck(request.args, page: request.page)
    guard let options = checked.options, let page = options.page else {
        return encoded(Refusal(error: checked.error ?? "invalid arguments"))
    }
    let flags = RowFlags(navigation: options.navigation, javascript: options.javascript, chromeless: options.chromeless,
                         persistent: options.persistent, browse: options.browse)
    return encoded(Checked(page: PageSource(page), flags: flags, color: options.backgroundColor, follow: options.follow))
}

private struct RowPage: Codable {
    let source: PageSource
    let flags: RowFlags
    var color: String?

    init(_ snapshot: PageSnapshot) {
        switch snapshot.source {
        case .file(let path, let grant): source = PageSource(.file(path: path, grantRoot: grant))
        case .url(let url): source = PageSource(.url(url))
        case .unreadable(let reason): source = PageSource(.unreadable(reason: reason))
        }
        flags = RowFlags(navigation: snapshot.navigation, javascript: snapshot.javascript, chromeless: snapshot.chromeless,
                         persistent: snapshot.persistent, browse: snapshot.browse)
        color = snapshot.backgroundColor
    }

    var snapshot: PageSnapshot? {
        let kept: PageSnapshot.Source
        switch source.source {
        case .file(let path, let grant): kept = .file(path: path, grantRoot: grant)
        case .url(let url): kept = .url(url)
        case .unreadable(let reason): kept = .unreadable(reason)
        default: return nil
        }
        return PageSnapshot(source: kept, javascript: flags.javascript, navigation: flags.navigation, chromeless: flags.chromeless,
                            persistent: flags.persistent, browse: flags.browse, backgroundColor: color)
    }
}

/// A saved session's `page` value, {"page": <value>} with the value as stored, read as the Mac's SessionSnapshot
/// reads it: {"row":{source,flags,color?},"saved":<PageSnapshot>} for a page row, an unreadable one included, and
/// {} for a terminal (absent or null).
@_cdecl("elis_page_snapshot_read")
public func elisPageSnapshotRead(_ json: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    struct Stored: Decodable {
        let page: PageSnapshot?
        enum CodingKeys: String, CodingKey { case page }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            do {
                page = try c.decodeIfPresent(PageSnapshot.self, forKey: .page)
            } catch {
                page = PageSnapshot(source: .unreadable(PageSnapshot.unreadableReason))
            }
        }
    }
    struct Read: Encodable {
        var row: RowPage?
        var saved: PageSnapshot?
    }
    guard let stored = decode(Stored.self, json), let page = stored.page else { return encoded(Read()) }
    return encoded(Read(row: RowPage(page), saved: page))
}

/// A page row's page, {source,flags,color?}, as the PageSnapshot JSON the Mac saves; null for a source a row cannot hold.
@_cdecl("elis_page_snapshot_write")
public func elisPageSnapshotWrite(_ json: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    struct Written: Encodable { let saved: PageSnapshot? }
    return encoded(Written(saved: decode(RowPage.self, json)?.snapshot))
}

/// PageSessionRefusal for one request: {"refused":true,"target":the session it addresses or null,"error"} when the
/// command is one a page session cannot take, else {"refused":false}. The host resolves `target` and refuses only
/// when it names a page row.
@_cdecl("elis_page_session_refusal")
public func elisPageSessionRefusal(_ json: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    struct Judged: Encodable {
        let refused: Bool
        var target: String?
        var error: String?
    }
    guard let request = decode(ControlRequest.self, json) else { return encoded(Judged(refused: false)) }
    var asked: String?
    let refusal = PageSessionRefusal.refusal(request) { target, _ in
        asked = target
        return true
    }
    guard let refusal else { return encoded(Judged(refused: false)) }
    return encoded(Judged(refused: true, target: asked, error: refusal.error))
}

/// A clicked terminal link's route, LinkPolicy's: {raw, mode, origin "pane"|"overlay", session, cwd?, modifiers
/// ["command","shift","option"], captured} -> {"route":"browser|overlay|image|markdown|text|document|reveal|session|
/// ignore", url?, path?, line?, sizePercent?, log?, session?}. A link only the filesystem can resolve is looked up here,
/// so the caller runs this off the GUI thread.
@_cdecl("elis_link_route")
public func elisLinkRoute(_ json: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    struct Request: Decodable {
        let raw: String
        var mode: String?
        let origin: String
        let session: String
        var cwd: String?
        var modifiers: [String]?
        var captured: Bool?
    }
    struct Routed: Encodable {
        let route: String
        var url: String?
        var path: String?
        var line: Int?
        var sizePercent: Int?
        var log: TextLog?
        var session: String?
    }
    guard let request = decode(Request.self, json) else { return encoded(Routed(route: "ignore")) }
    let session = UUID(uuidString: request.session) ?? UUID()
    let origin: LinkPolicy.ClickOrigin = request.origin == "pane" ? .pane(session) : .programOverlay
    let names: [String: KeyModifiers] = ["command": .command, "shift": .shift, "option": .option, "control": .control]
    let modifiers = (request.modifiers ?? []).reduce(into: KeyModifiers()) { $0.formUnion(names[$1] ?? []) }
    let setting = LinkOpenMode(rawValue: request.mode ?? "") ?? .browser
    let intent = LinkPolicy.clickIntent(modifiers: modifiers, mode: setting, origin: origin, mouseCaptured: request.captured ?? false)
    let mode = intent == .browser ? LinkOpenMode.browser : setting
    let candidates = LinkPolicy.locations(for: request.raw, origin: origin, cwd: request.cwd)
    let route = LinkPolicy.resolvedRoute(for: request.raw, candidates: candidates, mode: mode, origin: origin) {
        FileManager.default.fileExists(atPath: $0)
    }
    let path = { (url: URL) in url.path(percentEncoded: false) }
    if intent == .reveal, let file = route.localFile { return encoded(Routed(route: "reveal", path: path(file))) }
    switch route {
    case .browser(let url): return encoded(Routed(route: "browser", url: url.absoluteString))
    case .overlay(let url, _, let percent): return encoded(Routed(route: "overlay", url: url.absoluteString, sizePercent: percent))
    case .image(let url, _): return encoded(Routed(route: "image", path: path(url)))
    case .markdown(let url, _, let percent): return encoded(Routed(route: "markdown", path: path(url), sizePercent: percent))
    case .document(let url, _, let percent): return encoded(Routed(route: "document", path: path(url), sizePercent: percent))
    case .text(let link):
        return encoded(Routed(route: "text", path: path(link.url), line: link.line, sizePercent: link.sizePercent,
                              log: link.opensAsLog ? TextLog(tail: TextPage.defaultTail, follow: true) : nil))
    case .reveal(let url): return encoded(Routed(route: "reveal", path: path(url)))
    case .selectSession(let id): return encoded(Routed(route: "session", session: id.uuidString.lowercased()))
    case .forwardRemote, .ignore: return encoded(Routed(route: "ignore"))
    }
}
