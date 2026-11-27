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

@Suite struct PageRowsTests {
    @Test func aPageRowTakesItsSourceAndFlags() {
        let reply = call(elisPageRowArguments(json(["page": true, "args": ["url": "http://localhost:3000", "browse": true, "color": "#102030"]])))
        #expect(reply["ok"] as? Bool == true)
        #expect((reply["page"] as? [String: Any])?["url"] as? String == "http://localhost:3000")
        #expect((reply["flags"] as? [String: Any])?["browse"] as? Bool == true)
        #expect(reply["color"] as? String == "#102030")
    }

    @Test func pageRowRefusalsAreTheMacs() {
        let cases: [(Bool, [String: Any], String)] = [
            (true, ["markdownFile": "/a.md"], OverlayHtmlError.pageSessionNeedsPage),
            (false, ["command": "htop"], OverlayHtmlError.companionNeedsPage),
            (true, ["url": "https://x.test", "pane": "left"], "a page session is full size: it takes no --pane, --size-percent, --width or --height"),
            (false, ["url": "https://x.test", "sizePercent": 50], "a page companion is full size: it takes no --pane, --size-percent, --width or --height"),
            (true, ["url": "https://x.test", "color": "red"], "invalid color: red (#rrggbb)"),
        ]
        for (page, args, error) in cases {
            #expect(call(elisPageRowArguments(json(["page": page, "args": args])))["error"] as? String == error)
        }
    }

    @Test func aMacWrittenSnapshotReadsBackAsWritten() {
        let saved: [String: Any] = ["file": "/srv/site/index.html", "grantRoot": "/srv/site", "javascript": true, "backgroundColor": "#000000"]
        let read = call(elisPageSnapshotRead(json(["page": saved])))
        let row = read["row"] as? [String: Any]
        #expect((row?["source"] as? [String: Any])?["cwd"] as? String == "/srv/site")
        #expect((row?["flags"] as? [String: Any])?["javascript"] as? Bool == true)
        #expect(row?["color"] as? String == "#000000")
        #expect(NSDictionary(dictionary: read["saved"] as? [String: Any] ?? [:]).isEqual(to: saved))
        let written = call(elisPageSnapshotWrite(json(row ?? [:])))
        #expect(NSDictionary(dictionary: written["saved"] as? [String: Any] ?? [:]).isEqual(to: saved))
    }

    @Test func anUndecodablePageIsUnreadableAndNullIsATerminal() {
        for value: Any in [["url": "ftp://x.test"], 42, "page", ["neither": true]] {
            let read = call(elisPageSnapshotRead(json(["page": value])))
            #expect((read["saved"] as? [String: Any])?["unreadable"] as? String == PageSnapshot.unreadableReason)
            #expect(((read["row"] as? [String: Any])?["source"] as? [String: Any])?["kind"] as? String == "unreadable")
        }
        #expect(call(elisPageSnapshotRead(json(["page": NSNull()]))).isEmpty)
        #expect(call(elisPageSnapshotRead("{}")).isEmpty)
    }

    @Test func terminalCommandsAreRefusedOnAPageRow() {
        let typed = call(elisPageSessionRefusal(json(["cmd": "session.type", "target": "abc", "args": ["text": "x"]])))
        #expect(typed["refused"] as? Bool == true)
        #expect(typed["target"] as? String == "abc")
        #expect(typed["error"] as? String == "session.type: not available on a page session")
        #expect(call(elisPageSessionRefusal(json(["cmd": "session.rename", "args": ["name": "x"]])))["refused"] as? Bool == false)
        #expect(call(elisPageSessionRefusal(json(["cmd": "session.overlay.resize", "args": ["full": true]])))["refused"] as? Bool == false)
    }

    @Test func aWebLinkOpensAtTheModesSizeAndTheBrowserChordSkipsIt() {
        let base: [String: Any] = ["raw": "https://example.com/a", "mode": "overlay75", "origin": "pane", "session": UUID().uuidString]
        let routed = call(elisLinkRoute(json(base.merging(["modifiers": ["command"]]) { $1 })))
        #expect(routed["route"] as? String == "overlay")
        #expect(routed["sizePercent"] as? Int == 75)
        #expect(call(elisLinkRoute(json(base.merging(["modifiers": ["command", "shift"]]) { $1 })))["route"] as? String == "browser")
        #expect(call(elisLinkRoute(json(base.merging(["origin": "overlay"]) { $1 })))["route"] as? String == "browser")
    }

    @Test func localFilesRouteByKindAndTheRevealChordReveals() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["notes.md", "main.swift", "data.bin"] { try Data("x".utf8).write(to: dir.appendingPathComponent(name)) }
        let base: [String: Any] = ["mode": "", "origin": "pane", "session": UUID().uuidString, "cwd": dir.path, "modifiers": ["command"]]
        let route = { (raw: String, extra: [String: Any]) in call(elisLinkRoute(json(base.merging(extra.merging(["raw": raw]) { $1 }) { $1 }))) }
        #expect(route(dir.path + "/notes.md", [:])["route"] as? String == "markdown")
        #expect(route(dir.path + "/notes.md", [:])["sizePercent"] as? Int == 95)
        let text = route(dir.path + "/main.swift:12", [:])
        #expect(text["route"] as? String == "text")
        #expect(text["line"] as? Int == 12)
        #expect(route(dir.path + "/data.bin", [:])["route"] as? String == "reveal")
        #expect(route(dir.path + "/notes.md", ["modifiers": ["command", "option"]])["route"] as? String == "reveal")
    }
}
