import ElisCore
import Foundation

// Markdown, image, text and document pages: the open check, the documents a page loads, a log page's reads and the
// text-page commands, from ElisCore's builders and limits. The Mac's MarkdownProbe, ImageProbe and DocumentProbe live
// in its app target, on ImageIO; these are their header-only twins. Nothing here touches the main actor, so a host
// may call it from any thread.

/// A picture's bytes, type and oriented pixel size, read once through one descriptor.
private func picture(path: String, maxBytes: Int) -> Result<(mimeType: String, data: Data, pixels: ImagePixels), ImageFile.Failure> {
    BoundedFile.read(path: path, maxBytes: maxBytes).mapError { ImageFile.Failure($0, path: path) }.flatMap { data in
        guard let mime = ImagePage.mimeType(sniffing: data), let pixels = ImageHeader.pixels(data) else {
            return .failure(.notAnImage(path))
        }
        guard ImagePage.allowsPixels(width: pixels.width, height: pixels.height) else { return .failure(.tooManyPixels(path)) }
        return .success((mime, data, pixels))
    }
}

private struct Failed: Error, CustomStringConvertible {
    let description: String
}

/// A clicked HTML file's text with the page's policy ahead of it, worded as the Mac's DocumentProbe.
private func documentPage(path: String) -> Result<String, Failed> {
    switch BoundedFile.read(path: path, maxBytes: DocumentPage.maxBytes) {
    case .failure(.tooLarge): return .failure(Failed(description: "html file too large (over \(DocumentPage.maxBytes >> 20) MB): \(path)"))
    case .failure: return .failure(Failed(description: "unreadable html file: \(path)"))
    case .success(let data):
        return DocumentPage.page(data).map(Result.success) ?? .failure(Failed(description: "not a UTF-8 html file: \(path)"))
    }
}

private struct Built: Encodable {
    var html: String?
    var error: String?
}

private func built<F: Error & CustomStringConvertible>(_ result: Result<String, F>) -> UnsafeMutablePointer<CChar>? {
    switch result {
    case .success(let html): return encoded(Built(html: html))
    case .failure(let failure): return encoded(Built(error: failure.description))
    }
}

/// `session.overlay.open`'s file check for a page source, run after the slot's hidden check as the Mac runs it:
/// {"ok":true,"navigation","links"?,"pixels"?,"language"?,"diff"} or `session.overlay.open: <failure>`. `navigation`
/// drops for a markdown page whose folder grants no links. Input {source,navigation?,log?}.
@_cdecl("elis_page_open_check")
public func elisPageOpenCheck(_ json: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    struct Request: Decodable {
        let source: PageSource
        var navigation: Bool?
        var log: TextLog?
    }
    struct Pixels: Encodable {
        let width: Int
        let height: Int
    }
    struct Checked: Encodable {
        var ok = true
        let navigation: Bool
        var links: MarkdownLinkGrant?
        var pixels: Pixels?
        var language: String?
        var diff = false
    }
    guard let request = decode(Request.self, json), let source = request.source.source else {
        return encoded(Refusal(error: "invalid page"))
    }
    let refuse = { (failure: String) in encoded(Refusal(error: "session.overlay.open: \(failure)")) }
    var checked = Checked(navigation: request.navigation ?? false)
    switch source {
    case .image(let path):
        switch ImageFile.pixels(path: path) {
        case .failure(let failure): return refuse(failure.description)
        case .success(let pixels): checked.pixels = Pixels(width: pixels.width, height: pixels.height)
        }
    case .markdown(let path):
        if case .failure(let failure) = MarkdownFile.check(path: path) { return refuse(failure.description) }
        checked.links = checked.navigation ? MarkdownPage.linkGrant(for: path) : nil
        checked = Checked(navigation: checked.links != nil, links: checked.links)
    case .text(let path, _):
        let read = request.log.map { TextProbe.checkLog(path: path, tail: $0.tail) } ?? TextProbe.check(path: path)
        if case .failure(let failure) = read { return refuse(failure.description) }
        checked.language = TextPage.language(forFile: path)
        checked.diff = request.log == nil && TextPage.isDiff(file: path)
    case .document(let path):
        if case .failure(let failure) = documentPage(path: path) { return refuse(failure.description) }
    default:
        break
    }
    return encoded(checked)
}

/// The renderers and stylesheets in a `markdown` assets folder: {"script","style","textScript","textStyle"}.
@_cdecl("elis_markdown_assets")
public func elisMarkdownAssets(_ directory: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    struct Assets: Encodable {
        let script, style, textScript, textStyle: String
    }
    let assets = MarkdownAssets(directory: URL(fileURLWithPath: String(cString: directory)))
    return encoded(Assets(script: assets.script, style: assets.style, textScript: assets.textScript, textStyle: assets.textStyle))
}

/// A markdown page's document, its local pictures embedded within the page's budgets: {"html"} or {"error"}. `links`
/// keeps relative links to neighbouring markdown files. Input {path,links?,style}.
@_cdecl("elis_markdown_page")
public func elisMarkdownPage(_ json: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    struct Request: Decodable {
        let path: String
        var links: Bool?
        let style: String
    }
    guard let request = decode(Request.self, json) else { return encoded(Built(error: "invalid page")) }
    let path = request.path
    let read = BoundedFile.read(path: path, maxBytes: MarkdownPage.maxBytes).mapError { MarkdownFile.Failure($0, path: path) }
    return built(read.flatMap { data -> Result<String, MarkdownFile.Failure> in
        guard let markdown = String(data: data, encoding: .utf8) else { return .failure(.notText(path)) }
        var embedding = MarkdownEmbedding()
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
        for image in MarkdownPage.imageReferences(in: markdown, folder: folder) {
            guard let room = embedding.room(for: image) else { continue }
            let read = try? picture(path: image.path, maxBytes: room).get()
            embedding.add(image, read.map { ($0.mimeType, $0.data, $0.pixels.width * $0.pixels.height) })
        }
        return .success(MarkdownPage.html(markdown: markdown, images: embedding.embedded, style: request.style,
                                          links: request.links ?? false))
    })
}

/// The file a link page reads for a requested path, judged by `MarkdownPage.linkedDocument` after symlink resolution:
/// {"path"}, or {} when it is refused. Input {path,links:{path,root}}.
@_cdecl("elis_markdown_linked_document")
public func elisMarkdownLinkedDocument(_ json: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    struct Request: Decodable {
        let path: String
        let links: MarkdownLinkGrant
    }
    struct Linked: Encodable { let path: String? }
    let request = decode(Request.self, json)
    return encoded(Linked(path: request.flatMap { MarkdownPage.linkedDocument($0.path, grant: $0.links) }))
}

/// An image page's document: {"html"} or {"error"}. Input {path}.
@_cdecl("elis_image_page")
public func elisImagePage(_ json: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    struct Request: Decodable { let path: String }
    guard let request = decode(Request.self, json) else { return encoded(Built(error: "invalid page")) }
    return built(picture(path: request.path, maxBytes: ImagePage.maxBytes).map { ImagePage.html(data: $0.data, mimeType: $0.mimeType) })
}

/// An unsized image page's content size in points, `ImagePage.points` for a picture of `width` x `height` pixels on a
/// display of `scale` inside `bounds`: {"width","height","percent"}. Input {width,height,scale,zoom,bounds?:{width,height}}.
@_cdecl("elis_image_points")
public func elisImagePoints(_ json: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    struct Size: Codable {
        let width: Double
        let height: Double
    }
    struct Request: Decodable {
        let width: Int
        let height: Int
        let scale: Double
        let zoom: Double
        var bounds: Size?
    }
    struct Points: Encodable {
        let width: Int
        let height: Int
        let percent: Int
    }
    guard let request = decode(Request.self, json) else { return encoded(Refusal(error: "invalid size")) }
    let natural = ImagePage.natural(pixelWidth: request.width, pixelHeight: request.height, orientation: 1, scale: request.scale)
    let bounds = request.bounds.map { HudPaneFrame(x: 0, y: 0, width: $0.width, height: $0.height) }
    let points = ImagePage.points(natural: natural, zoom: request.zoom, bounds: bounds)
    return encoded(Points(width: points.width ?? 1, height: points.height ?? 1, percent: ImagePage.basePercent))
}

/// A clicked HTML file's document, network off by its policy: {"html"} or {"error"}. Input {path}.
@_cdecl("elis_document_page")
public func elisDocumentPage(_ json: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    struct Request: Decodable { let path: String }
    guard let request = decode(Request.self, json) else { return encoded(Built(error: "invalid page")) }
    return built(documentPage(path: request.path))
}

/// A text page's file, read and validated: {"text"} or {"error"}. Input {path}.
@_cdecl("elis_text_load")
public func elisTextLoad(_ json: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    struct Request: Decodable { let path: String }
    struct Loaded: Encodable {
        var text: String?
        var error: String?
    }
    guard let request = decode(Request.self, json) else { return encoded(Loaded(error: "invalid page")) }
    switch TextProbe.load(path: request.path) {
    case .success(let text): return encoded(Loaded(text: text))
    case .failure(let failure): return encoded(Loaded(error: failure.description))
    }
}

/// A text or log page's document from text in hand, `TextPage.html`: {"html"}. Input {text,path,line?,style,
/// log?:{following,lines,clipped,waiting,unreadable},anchor?,search?:{query,revision,current},change?,entered?,file?,wrap?}.
@_cdecl("elis_text_page")
public func elisTextPage(_ json: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    struct Log: Decodable {
        let following: Bool
        var lines: Int?
        var clipped: Bool?
        var waiting: Bool?
        var unreadable: Bool?
    }
    struct Search: Decodable {
        let query: String
        let revision: Int
        let current: Int
    }
    struct Request: Decodable {
        let text: String
        let path: String
        var line: Int?
        let style: String
        var log: Log?
        var anchor: Double?
        var search: Search?
        var change: Int?
        var entered: Bool?
        var file: Int?
        var wrap: Bool?
    }
    guard let r = decode(Request.self, json) else { return encoded(Built(error: "invalid page")) }
    let log = r.log.map {
        TextLogState(following: $0.following, report: TextLogReport(lines: $0.lines ?? 0, clipped: $0.clipped ?? false,
                                                                    waiting: $0.waiting ?? false, unreadable: $0.unreadable ?? false))
    }
    let search = r.search.map { TextPage.SearchState(query: $0.query, revision: $0.revision, current: $0.current) }
    let html = TextPage.html(text: r.text, language: TextPage.language(forFile: r.path), line: r.line, style: r.style, log: log,
                             anchor: r.anchor, search: search, change: r.change, entered: r.entered ?? false, file: r.file,
                             wrap: r.wrap ?? false)
    return encoded(Built(html: html))
}

private struct LogSnapshot: Codable {
    let text: String
    let lines: Int
    let clipped: Bool
    let startOffset: Int

    var tail: LogTail.Snapshot { LogTail.Snapshot(text: text, lines: lines, clipped: clipped, startOffset: startOffset) }
}

private func stamp(_ text: String?) -> BoundedFile.FileStamp? {
    text.flatMap { try? JSONDecoder().decode(BoundedFile.FileStamp.self, from: Data($0.utf8)) }
}

/// A log page's read of its file's last `tail` lines: {"unchanged":true} while the file keeps `stamp`, else {"stamp",
/// "snapshot"?}, the snapshot absent when the file's end is binary, or {"error"} when it cannot be read. The stamp is
/// opaque: hand it back as it came. Input {path,tail,stamp?}.
@_cdecl("elis_text_log_read")
public func elisTextLogRead(_ json: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    struct Request: Decodable {
        let path: String
        let tail: Int
        var stamp: String?
    }
    struct Read: Encodable {
        var unchanged: Bool?
        var stamp: String?
        var snapshot: LogSnapshot?
        var error: String?
    }
    guard let request = decode(Request.self, json) else { return encoded(Read(error: "invalid page")) }
    switch TextProbe.loadLog(path: request.path, tail: request.tail, unchangedFrom: stamp(request.stamp)) {
    case .failure(let failure): return encoded(Read(error: failure.description))
    case .success(nil): return encoded(Read(unchanged: true))
    case .success(let read?):
        let text = (try? JSONEncoder().encode(read.stamp)).map { String(decoding: $0, as: UTF8.self) }
        let shown = read.snapshot.map { LogSnapshot(text: $0.text, lines: $0.lines, clipped: $0.clipped, startOffset: $0.startOffset) }
        return encoded(Read(stamp: text, snapshot: shown))
    }
}

/// How the text a log push carries relates to what the page shows, LogTail.shift: {"dropped","cut","replaced"}.
/// Input {old?,oldStamp?,new?,newStamp?}, snapshots as `elis_text_log_read` gives them.
@_cdecl("elis_text_log_shift")
public func elisTextLogShift(_ json: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    struct Request: Decodable {
        var old: LogSnapshot?
        var oldStamp: String?
        var new: LogSnapshot?
        var newStamp: String?
    }
    struct Shifted: Encodable {
        let dropped: Int
        let cut: Bool
        let replaced: Bool
    }
    let request = decode(Request.self, json)
    let shift = LogTail.shift(from: request?.old?.tail, stamp: stamp(request?.oldStamp), to: request?.new?.tail, stamp: stamp(request?.newStamp))
    return encoded(Shifted(dropped: shift.dropped, cut: shift.cut, replaced: shift.replaced))
}

/// A text-page command's action from its arguments, `ControlDispatcher.textPageAction`: {"ok":true,"action":{kind,…}}
/// or the Mac's refusal. kind search carries `search` (query|next|previous|close) and `query`; follow and wrap a `mode`;
/// changes `forward`; files `to`. Input {cmd,args}.
@_cdecl("elis_overlay_text_action")
public func elisOverlayTextAction(_ json: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    struct Request: Decodable {
        let cmd: String
        var args: ControlArgs?
    }
    struct Action: Encodable {
        let kind: String
        var search: String?
        var query: String?
        var mode: String?
        var forward: Bool?
        var to: String?
    }
    struct Parsed: Encodable {
        var ok = true
        let action: Action
    }
    guard let request = decode(Request.self, json), let cmd = ElisCore.Command(rawValue: request.cmd) else {
        return encoded(Refusal(error: "invalid arguments"))
    }
    let parsed = ControlDispatcher.textPageAction(cmd, args: request.args)
    guard let action = parsed.action else { return encoded(Refusal(error: parsed.error ?? "invalid arguments")) }
    switch action {
    case .search(.query(let query)): return encoded(Parsed(action: Action(kind: "search", search: "query", query: query)))
    case .search(.next): return encoded(Parsed(action: Action(kind: "search", search: "next")))
    case .search(.previous): return encoded(Parsed(action: Action(kind: "search", search: "previous")))
    case .search(.close): return encoded(Parsed(action: Action(kind: "search", search: "close")))
    case .follow(let mode): return encoded(Parsed(action: Action(kind: "follow", mode: mode.rawValue)))
    case .wrap(let mode): return encoded(Parsed(action: Action(kind: "wrap", mode: mode.rawValue)))
    case .changes(let forward): return encoded(Parsed(action: Action(kind: "changes", forward: forward)))
    case .files(let to): return encoded(Parsed(action: Action(kind: "files", to: to)))
    }
}

/// The text-page limits and the refusals a host words itself: {"maxQuery","maxHighlightBytes","notLog","notText",
/// "notDiff","notLoaded","noQuery","noChanges","noFile"}, noFile with `%1` for the file asked for.
@_cdecl("elis_text_page_constants")
public func elisTextPageConstants() -> UnsafeMutablePointer<CChar>? {
    struct Constants: Encodable {
        let maxQuery = TextSearch.maxQuery
        let maxHighlightBytes = TextPage.maxHighlightBytes
        let notLog = TextLogFollowFailure.notLog.message
        let notText = TextSearchFailure.notText.message
        let notDiff = TextChangesFailure.notDiff.message
        let notLoaded = TextSearchFailure.notLoaded.message
        let noQuery = TextSearchFailure.noQuery.message
        let noChanges = TextChangesFailure.noChanges.message
        let noFile = TextChangesFailure.noFile("%1").message
    }
    return encoded(Constants())
}

/// Why `session.overlay.navigate` cannot hand page `kind` to the browser or the file manager: {"error"?}. Input {kind,to}.
@_cdecl("elis_page_navigate_refusal")
public func elisPageNavigateRefusal(_ json: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    struct Request: Decodable {
        let kind: String
        let to: String
    }
    struct Refused: Encodable { let error: String? }
    let request = decode(Request.self, json)
    let refusals = ["markdown": OverlayHtmlError.markdownInOverlay, "text": OverlayHtmlError.textInOverlay,
                    "document": OverlayHtmlError.documentInOverlay]
    switch request?.to {
    case "browser": return encoded(Refused(error: request.flatMap { refusals[$0.kind] }))
    case "finder": return encoded(Refused(error: request?.kind == "file" ? nil : OverlayHtmlError.finderRequiresFile))
    default: return encoded(Refused(error: nil))
    }
}
