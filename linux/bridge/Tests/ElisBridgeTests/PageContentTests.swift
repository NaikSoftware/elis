@testable import ElisBridge
import ElisCore
import Foundation
import Testing

private func call(_ result: UnsafeMutablePointer<CChar>?) -> [String: Any] {
    defer { free(result) }
    let data = Data(String(cString: result!).utf8)
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

private func json(_ value: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self)
}

// a 3 x 2 PNG header, all ImageHeader reads
private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13] + Array("IHDR".utf8) + [0, 0, 0, 3, 0, 0, 0, 2, 8, 6, 0, 0, 0])

private func folder() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("page-content-\(UUID().uuidString)/docs")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.resolvingSymlinksInPath()
}

@Suite struct PageContentTests {
    @Test func theOpenCheckRefusesAsTheMacDoes() throws {
        let dir = try folder()
        let missing = dir.appendingPathComponent("gone.png").path
        let image = call(elisPageOpenCheck(json(["source": ["kind": "image", "path": missing]])))
        #expect(image["error"] as? String == "session.overlay.open: \(ImageFile.Failure.unreadable(missing))")
        let binary = dir.appendingPathComponent("a.txt")
        try Data([0x61, 0, 0x62]).write(to: binary)
        let text = call(elisPageOpenCheck(json(["source": ["kind": "text", "path": binary.path]])))
        #expect(text["error"] as? String == "session.overlay.open: \(TextProbe.Failure.notText(binary.path))")
    }

    @Test func aMarkdownPageNavigatesOnlyWithALinkGrant() throws {
        let dir = try folder()
        let file = dir.appendingPathComponent("guide.md")
        try Data("# hi".utf8).write(to: file)
        let checked = call(elisPageOpenCheck(json(["source": ["kind": "markdown", "path": file.path], "navigation": true])))
        #expect(checked["navigation"] as? Bool == true)
        #expect((checked["links"] as? [String: Any])?["root"] as? String == dir.path)
        let plain = call(elisPageOpenCheck(json(["source": ["kind": "markdown", "path": file.path]])))
        #expect(plain["navigation"] as? Bool == false)
        #expect(plain["links"] == nil)
    }

    @Test func aMarkdownPageEmbedsItsLocalPictures() throws {
        let dir = try folder()
        try png.write(to: dir.appendingPathComponent("p.png"))
        let file = dir.appendingPathComponent("a.md")
        try Data("![p](p.png) ![o](../out.png)".utf8).write(to: file)
        let html = call(elisMarkdownPage(json(["path": file.path, "style": "S"])))["html"] as? String ?? ""
        #expect(html.contains("base64,\(png.base64EncodedString())") && html.contains("{&quot;p.png&quot;:0}"))
        #expect(html.contains("<style>S</style>"))
        #expect(!html.contains("data-links"))
    }

    @Test func aLinkedDocumentStaysInsideTheGrantAfterSymlinks() throws {
        let dir = try folder()
        let secret = dir.deletingLastPathComponent().appendingPathComponent(".env")
        try Data("KEY=1".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("alias.md"), withDestinationURL: secret)
        try Data("x".utf8).write(to: dir.appendingPathComponent("next.md"))
        let grant: [String: Any] = ["path": dir.appendingPathComponent("a.md").path, "root": dir.path]
        let next = call(elisMarkdownLinkedDocument(json(["path": dir.appendingPathComponent("next.md").path, "links": grant])))
        #expect(next["path"] as? String == dir.appendingPathComponent("next.md").path)
        #expect(call(elisMarkdownLinkedDocument(json(["path": dir.appendingPathComponent("alias.md").path, "links": grant])))["path"] == nil)
        #expect(call(elisMarkdownLinkedDocument(json(["path": dir.path + "/../a.md", "links": grant])))["path"] == nil)
    }

    @Test func anImagePageIsTheMacsDocument() throws {
        let file = try folder().appendingPathComponent("p.png")
        try png.write(to: file)
        #expect(call(elisImagePage(json(["path": file.path])))["html"] as? String == ImagePage.html(data: png, mimeType: "image/png"))
        let points = call(elisImagePoints(json(["width": 3, "height": 2, "scale": 1, "zoom": 1])))
        let expected = ImagePage.points(natural: (3, 2), zoom: 1)
        #expect(points["width"] as? Int == expected.width && points["height"] as? Int == expected.height)
        #expect(points["percent"] as? Int == ImagePage.basePercent)
    }

    @Test func aDocumentCarriesItsPolicy() throws {
        let file = try folder().appendingPathComponent("x.html")
        try Data("<!doctype html><p>hi".utf8).write(to: file)
        #expect(call(elisDocumentPage(json(["path": file.path])))["html"] as? String == DocumentPage.page(Data("<!doctype html><p>hi".utf8)))
        #expect(call(elisDocumentPage(json(["path": "/nope.html"])))["error"] as? String == "unreadable html file: /nope.html")
    }

    @Test func aTextPageIsBuiltFromItsState() {
        let request: [String: Any] = ["text": "a\nb", "path": "/x.swift", "line": 2, "style": "S", "wrap": true,
                                      "search": ["query": "b", "revision": 3, "current": 1]]
        let html = call(elisTextPage(json(request)))["html"] as? String
        #expect(html == TextPage.html(text: "a\nb", language: "swift", line: 2, style: "S",
                                      search: TextPage.SearchState(query: "b", revision: 3, current: 1), wrap: true))
    }

    @Test func aLogReadIsUnchangedUntilItsFileMoves() throws {
        let file = try folder().appendingPathComponent("a.log")
        try Data("one\ntwo\n".utf8).write(to: file)
        let first = call(elisTextLogRead(json(["path": file.path, "tail": 1])))
        #expect((first["snapshot"] as? [String: Any])?["text"] as? String == "two\n")
        let stamp = try #require(first["stamp"] as? String)
        #expect(call(elisTextLogRead(json(["path": file.path, "tail": 1, "stamp": stamp])))["unchanged"] as? Bool == true)
        try Data("one\ntwo\nthree\n".utf8).write(to: file)
        let second = call(elisTextLogRead(json(["path": file.path, "tail": 1, "stamp": stamp])))
        #expect((second["snapshot"] as? [String: Any])?["text"] as? String == "three\n")
        #expect(call(elisTextLogRead(json(["path": "/nope.log", "tail": 1])))["error"] as? String == "\(TextProbe.Failure.unreadable("/nope.log"))")
    }

    @Test func aShiftCountsTheLinesThatLeftTheFront() {
        let stamp = { (size: Int) in
            String(decoding: try! JSONEncoder().encode(BoundedFile.FileStamp(device: 1, inode: 2, size: size, modifiedSeconds: size,
                                                                              modifiedNanoseconds: 0)), as: UTF8.self)
        }
        let old: [String: Any] = ["text": "a\nb\nc", "lines": 3, "clipped": false, "startOffset": 0]
        let new: [String: Any] = ["text": "b\nc\nd", "lines": 3, "clipped": false, "startOffset": 2]
        let shift = call(elisTextLogShift(json(["old": old, "oldStamp": stamp(5), "new": new, "newStamp": stamp(7)])))
        #expect(shift["dropped"] as? Int == 1 && shift["cut"] as? Bool == false && shift["replaced"] as? Bool == false)
        let other = call(elisTextLogShift(json(["old": old, "oldStamp": stamp(5), "new": new, "newStamp": stamp(3)])))
        #expect(other["replaced"] as? Bool == true)
    }

    @Test func textActionsParseAsTheMacsDispatcher() {
        let next = call(elisOverlayTextAction(json(["cmd": "session.overlay.search", "args": ["to": "next"]])))
        #expect((next["action"] as? [String: Any])?["search"] as? String == "next")
        let both = call(elisOverlayTextAction(json(["cmd": "session.overlay.search", "args": ["to": "next", "text": "x"]])))
        #expect(both["error"] as? String == OverlayHtmlError.searchTextWithStep)
        let follow = call(elisOverlayTextAction(json(["cmd": "session.overlay.follow", "args": [:]])))
        #expect((follow["action"] as? [String: Any])?["mode"] as? String == "toggle")
        let wrap = call(elisOverlayTextAction(json(["cmd": "session.overlay.wrap", "args": ["mode": "sideways"]])))
        #expect(wrap["error"] as? String == "invalid overlay wrap mode: sideways")
        let files = call(elisOverlayTextAction(json(["cmd": "session.overlay.files", "args": [:]])))
        #expect(files["error"] as? String == "session.overlay.files requires to, a file number or path")
    }

    @Test func navigationRefusalsAreElisCores() {
        #expect(call(elisPageNavigateRefusal(json(["kind": "text", "to": "browser"])))["error"] as? String == OverlayHtmlError.textInOverlay)
        #expect(call(elisPageNavigateRefusal(json(["kind": "image", "to": "browser"])))["error"] == nil)
        #expect(call(elisPageNavigateRefusal(json(["kind": "markdown", "to": "finder"])))["error"] as? String == OverlayHtmlError.finderRequiresFile)
        #expect(call(elisTextPageConstants())["noFile"] as? String == "no file %1")
    }
}
