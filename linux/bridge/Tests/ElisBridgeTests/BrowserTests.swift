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

private func scratch() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite struct BrowserTests {
    @Test func aMissingProfileIsCreatedOnceAndKept() throws {
        let dir = scratch()
        #expect(call(elisBrowserClear(json(["directory": dir.path, "openPages": 0])))["id"] == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("browser-profile").path))
        let id = try #require(call(elisBrowserProfile(json(["directory": dir.path])))["id"] as? String)
        #expect(UUID(uuidString: id) != nil)
        #expect(call(elisBrowserProfile(json(["directory": dir.path])))["id"] as? String == id)
        #expect(call(elisBrowserClear(json(["directory": dir.path, "openPages": 0])))["id"] as? String == id)
    }

    @Test func aBrokenProfileRefusesAndIsLeftAlone() throws {
        let dir = scratch()
        let file = dir.appendingPathComponent("browser-profile")
        try Data("not a uuid\n".utf8).write(to: file)
        let reply = call(elisBrowserProfile(json(["directory": dir.path])))
        #expect(reply["ok"] as? Bool == false)
        #expect(reply["error"] as? String == BrowserProfile.Failure.malformed(file.path).description)
        #expect(try String(contentsOf: file, encoding: .utf8) == "not a uuid\n")
        #expect(call(elisBrowserClear(json(["directory": dir.path, "openPages": 0])))["error"] as? String
            == "browser.clear: \(BrowserProfile.Failure.malformed(file.path))")

        let unreadable = scratch()
        try FileManager.default.createDirectory(at: unreadable.appendingPathComponent("browser-profile"), withIntermediateDirectories: true)
        #expect(call(elisBrowserProfile(json(["directory": unreadable.path])))["error"] as? String
            == BrowserProfile.Failure.unreadable(unreadable.appendingPathComponent("browser-profile").path).description)
        #expect(call(elisBrowserProfile(json([:])))["error"] as? String == OverlayHtmlError.persistentUnavailable)
    }

    @Test func clearRefusesWhileAPersistentPageIsOpenOrWhenTargeted() {
        let dir = scratch().path
        #expect(call(elisBrowserClear(json(["directory": dir, "openPages": 1])))["error"] as? String == "browser.clear: 1 persistent page still open")
        #expect(call(elisBrowserClear(json(["directory": dir, "openPages": 2])))["error"] as? String == "browser.clear: 2 persistent pages still open")
        #expect(call(elisBrowserClear(json(["directory": dir, "openPages": 0, "target": "active"])))["error"] as? String
            == "browser.clear takes no target or --window")
    }

    @Test func linksSetReadAndRefuse() {
        #expect(call(elisBrowserLinks(json(["current": ""])))["mode"] as? String == "browser")
        #expect(call(elisBrowserLinks(json(["current": "overlay75"])))["mode"] as? String == "overlay75")
        #expect(call(elisBrowserLinks(json(["current": "bogus"])))["mode"] as? String == "browser")
        #expect(call(elisBrowserLinks(json(["current": "", "mode": "overlay50"])))["mode"] as? String == "overlay50")
        #expect(call(elisBrowserLinks(json(["current": "", "mode": "tab"])))["error"] as? String == "invalid link mode: tab")
        #expect(call(elisBrowserLinks(json(["current": "", "window": "w"])))["error"] as? String == "browser.links takes no target or --window")
    }
}
