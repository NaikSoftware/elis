import ElisCore
import Foundation

// Page overlays: ElisCore's source check, navigation policy, identity, theme, zoom and outcomes. A page travels as
// {"source":{"kind":"file","path","cwd"?}|{"kind":"url","url"}|{"kind":"image|markdown|text|document","path","line"?},
// "flags":{navigation,javascript,chromeless,persistent,browse},"id"?,"links"?}, the fields HtmlOverlay keeps.

struct PageSource: Codable {
    let kind: String
    var path: String?
    var cwd: String?
    var url: String?
    var line: Int?

    init(_ source: HtmlSource) {
        switch source {
        case .file(let path, let grant): kind = "file"; self.path = path; cwd = grant
        case .url(let url): kind = "url"; self.url = url.absoluteString
        case .image(let path): kind = "image"; self.path = path
        case .markdown(let path): kind = "markdown"; self.path = path
        case .text(let path, let line): kind = "text"; self.path = path; self.line = line
        case .document(let path): kind = "document"; self.path = path
        case .replica, .unreadable: kind = "unsupported"
        }
    }

    var source: HtmlSource? {
        switch kind {
        case "file": return path.map { .file(path: $0, grantRoot: cwd) }
        case "url": return url.flatMap(HtmlSource.webURL).map { .url($0) }
        case "image": return path.map { .image(path: $0) }
        case "markdown": return path.map { .markdown(path: $0) }
        case "text": return path.map { .text(path: $0, line: line) }
        case "document": return path.map { .document(path: $0) }
        default: return nil
        }
    }
}

private struct PageFlags: Decodable {
    var navigation: Bool?
    var javascript: Bool?
    var chromeless: Bool?
    var persistent: Bool?
    var browse: Bool?
}

private struct PageRequest: Decodable {
    let source: PageSource
    var flags: PageFlags?
    var page: String?
    var action: Action?
    /// id and links are a markdown page's own: its scheme address names the id, and its links stay in the grant.
    var id: String?
    var links: MarkdownLinkGrant?

    struct Action: Decodable {
        let url: String
        let target: String
        let userActivated: Bool
    }

    var overlay: HtmlOverlay? {
        guard let source = source.source else { return nil }
        var overlay = HtmlOverlay(source: source, navigation: flags?.navigation ?? false, javascript: flags?.javascript ?? false,
                                  chromeless: flags?.chromeless ?? false, persistent: flags?.persistent ?? false,
                                  browse: flags?.browse ?? false, id: id.flatMap(UUID.init(uuidString:)) ?? UUID(),
                                  markdownLinks: links)
        if let page { overlay.current = HtmlPageInfo(page: page, title: nil, canGoBack: false, canGoForward: false) }
        return overlay
    }
}

func decode<T: Decodable>(_ type: T.Type, _ json: UnsafePointer<CChar>) -> T? {
    try? JSONDecoder().decode(type, from: Data(String(cString: json).utf8))
}

/// `session.overlay.open`'s source check: {"ok":true,"page":null} for a program, the page source, or the Mac's refusal.
@_cdecl("elis_overlay_page_arguments")
public func elisOverlayPageArguments(_ argsJSON: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    struct Checked: Encodable {
        var ok = true
        let page: PageSource?
        /// log is a text page's tail and follow, as the Mac's dispatcher reads them.
        let log: TextLog?
    }
    guard let args = decode(ControlArgs.self, argsJSON) else { return encoded(Refusal(error: "invalid arguments")) }
    let checked = ControlDispatcher.overlayPage(command: args.command ?? "", args: args)
    if let error = checked.error { return encoded(Refusal(error: error)) }
    let log = checked.page?.textPath != nil && (args.tail != nil || args.followFile == true)
        ? TextLog(tail: args.tail ?? TextPage.defaultTail, follow: args.followFile == true) : nil
    return encoded(Checked(page: checked.page.map(PageSource.init), log: log))
}

/// One frame navigation judged by `HtmlNavigationPolicy`: {"decision":"allow|openExternal|cancel"}. A request that does
/// not decode is cancelled.
@_cdecl("elis_html_navigation_decide")
public func elisHtmlNavigationDecide(_ json: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    struct Decided: Encodable { let decision: String }
    let targets: [String: HtmlNavigationTarget] = ["mainFrame": .mainFrame, "subframe": .subframe, "newWindow": .newWindow]
    guard let request = decode(PageRequest.self, json), let overlay = request.overlay, let action = request.action,
          let url = URL(string: action.url), let target = targets[action.target] else {
        return encoded(Decided(decision: "cancel"))
    }
    let decision = HtmlNavigationPolicy.decide(HtmlNavigationAction(url: url, target: target, userActivated: action.userActivated),
                                               overlay: overlay)
    switch decision {
    case .allow: return encoded(Decided(decision: "allow"))
    case .openExternal: return encoded(Decided(decision: "openExternal"))
    case .cancel: return encoded(Decided(decision: "cancel"))
    }
}

/// The strip's identity, from the source and the committed `page`: {"identity"}.
@_cdecl("elis_html_identity")
public func elisHtmlIdentity(_ json: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    struct Identity: Encodable { let identity: String }
    guard let overlay = decode(PageRequest.self, json)?.overlay else { return encoded(Refusal(error: "invalid page")) }
    return encoded(Identity(identity: overlay.identity))
}

/// The theme user script, {"script"}, from {"background","foreground","dark","palette":[16 × #rrggbb],"themed"}.
@_cdecl("elis_html_theme_script")
public func elisHtmlThemeScript(_ json: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    struct Request: Decodable {
        let background: String
        let foreground: String
        let dark: Bool
        var palette: [String]?
        let themed: Bool
    }
    struct Script: Encodable { let script: String }
    guard let request = decode(Request.self, json) else { return encoded(Refusal(error: "invalid theme")) }
    let theme = HtmlOverlayTheme(background: request.background, foreground: request.foreground, dark: request.dark,
                                 palette: request.palette ?? [])
    return encoded(Script(script: theme.script(themed: request.themed)))
}

/// The page zoom after a font action, {"zoom"}, absent for an action that is not one, from {"action","zoom"}.
@_cdecl("elis_html_zoom")
public func elisHtmlZoom(_ json: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    struct Request: Decodable {
        let action: String
        let zoom: Double
    }
    struct Zoom: Encodable { let zoom: Double? }
    guard let request = decode(Request.self, json) else { return encoded(Zoom(zoom: nil)) }
    return encoded(Zoom(zoom: HtmlZoom.applying(fontAction: request.action, to: request.zoom)))
}

// HtmlPageOutcomes is main-actor state: these run on the process main thread, the Qt GUI thread.

/// Registers a new page as pending: {"pageID"}, the id the read-back and `result --page` use.
@_cdecl("elis_page_outcome_register")
public func elisPageOutcomeRegister() -> UnsafeMutablePointer<CChar>? {
    struct Registered: Encodable { let pageID: String }
    let id = UUID()
    MainActor.assumeIsolated { HtmlPageOutcomes.shared.register(id) }
    return encoded(Registered(pageID: id.uuidString))
}

/// Answers a pending page: {"ok":true}, or {"ok":false} when it is not waiting, so the first answer stands.
@_cdecl("elis_page_outcome_submit")
public func elisPageOutcomeSubmit(_ pageID: UnsafePointer<CChar>, _ value: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    struct Submitted: Encodable { let ok: Bool }
    guard let id = UUID(uuidString: String(cString: pageID)) else { return encoded(Submitted(ok: false)) }
    let value = String(cString: value)
    return encoded(Submitted(ok: MainActor.assumeIsolated { HtmlPageOutcomes.shared.submit(id, value: value) }))
}

/// Records a page that left its slot unanswered as dismissed; an answered one keeps its outcome.
@_cdecl("elis_page_outcome_dismiss")
public func elisPageOutcomeDismiss(_ pageID: UnsafePointer<CChar>) {
    guard let id = UUID(uuidString: String(cString: pageID)) else { return }
    MainActor.assumeIsolated { HtmlPageOutcomes.shared.dismiss(id) }
}

/// `session.overlay.result --page ID`'s whole reply.
@_cdecl("elis_page_outcome_result")
public func elisPageOutcomeResult(_ pageID: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    guard let id = UUID(uuidString: String(cString: pageID)) else {
        return encoded(ControlResponse(ok: false, error: OverlayHtmlError.invalidPageID))
    }
    return encoded(MainActor.assumeIsolated { HtmlPageOutcomes.shared.response(for: id) })
}
