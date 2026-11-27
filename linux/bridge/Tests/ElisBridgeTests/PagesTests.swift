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

@Suite struct PagesTests {
    @Test func aFilePageWithItsGrantPasses() {
        let reply = call(elisOverlayPageArguments(json(["html": "/srv/site/index.html", "cwd": "/srv/site"])))
        #expect(reply["ok"] as? Bool == true)
        let page = reply["page"] as? [String: Any]
        #expect(page?["kind"] as? String == "file")
        #expect(page?["path"] as? String == "/srv/site/index.html")
        #expect(page?["cwd"] as? String == "/srv/site")
    }

    @Test func aProgramHasNoPage() {
        let reply = call(elisOverlayPageArguments(json(["command": "htop"])))
        #expect(reply["ok"] as? Bool == true)
        #expect(reply["page"] == nil || reply["page"] is NSNull)
    }

    @Test func pageRefusalsAreTheMacs() {
        let cases: [([String: Any], String)] = [
            (["html": "/a.html", "url": "https://x.test"], OverlayHtmlError.htmlAndURL),
            (["url": "https://x.test", "chromeless": true], OverlayHtmlError.chromelessRequiresLoopback),
            (["html": "/a.html", "browse": true], OverlayHtmlError.browseRequiresURL),
            (["url": "ftp://x.test"], OverlayHtmlError.invalidURL),
            (["html": "/srv/a/x.html", "cwd": "/srv/b"], "session.overlay.open: html file is outside cwd"),
            (["navigation": true], OverlayHtmlError.navigationWithoutPage),
        ]
        for (args, error) in cases {
            let reply = call(elisOverlayPageArguments(json(args)))
            #expect(reply["ok"] as? Bool == false)
            #expect(reply["error"] as? String == error)
        }
    }

    private func decide(_ source: [String: Any], flags: [String: Any] = [:], url: String, target: String = "mainFrame",
                        clicked: Bool = false) -> String? {
        let request: [String: Any] = ["source": source, "flags": flags,
                                      "action": ["url": url, "target": target, "userActivated": clicked]]
        return call(elisHtmlNavigationDecide(json(request)))["decision"] as? String
    }

    @Test func aUrlPageStaysOnItsOrigin() {
        let source = ["kind": "url", "url": "http://127.0.0.1:8000/"]
        #expect(decide(source, url: "http://127.0.0.1:8000/next") == "allow")
        #expect(decide(source, url: "http://127.0.0.1:9000/") == "cancel")
        #expect(decide(source, url: "http://127.0.0.1:9000/", clicked: true) == "openExternal")
        #expect(decide(source, flags: ["browse": true], url: "https://example.org/") == "allow")
    }

    @Test func aFilePageReadsOnlyInsideItsGrant() {
        let source = ["kind": "file", "path": "/srv/site/index.html", "cwd": "/srv/site"]
        #expect(decide(source, url: "file:///srv/site/b.html", target: "subframe") == "allow")
        #expect(decide(source, url: "file:///srv/other.html", target: "subframe") == "cancel")
        #expect(decide(["kind": "file", "path": "/srv/site/index.html"], url: "file:///srv/site/b.html") == "cancel")
    }

    @Test func undecodableNavigationIsCancelled() {
        #expect(call(elisHtmlNavigationDecide("{}"))["decision"] as? String == "cancel")
    }

    @Test func identityFollowsTheBrowsedOrigin() {
        let url: [String: Any] = ["source": ["kind": "url", "url": "https://a.test/x"], "flags": ["browse": true], "page": "https://b.test/y"]
        #expect(call(elisHtmlIdentity(json(url)))["identity"] as? String == "https://b.test")
        let file = ["source": ["kind": "file", "path": "/srv/site/index.html"]]
        #expect(call(elisHtmlIdentity(json(file)))["identity"] as? String == "index.html")
    }

    @Test func zoomWalksTheLadder() {
        #expect(call(elisHtmlZoom(json(["action": "increase_font_size:1", "zoom": 1])))["zoom"] as? Double == 1.15)
        #expect(call(elisHtmlZoom(json(["action": "reset_font_size", "zoom": 2])))["zoom"] as? Double == 1)
        #expect(call(elisHtmlZoom(json(["action": "copy", "zoom": 2])))["zoom"] == nil)
    }

    @Test func themeScriptCarriesTheColors() {
        let request: [String: Any] = ["background": "#101010", "foreground": "#eeeeee", "dark": true, "themed": true]
        let script = call(elisHtmlThemeScript(json(request)))["script"] as? String
        #expect(script?.contains("--elis-background: #101010") == true)
        #expect(script?.contains("color-scheme: dark") == true)
    }

    @MainActor @Test func outcomesFollowThePage() {
        let id = call(elisPageOutcomeRegister())["pageID"] as! String
        #expect((call(elisPageOutcomeResult(id))["result"] as? [String: Any])?["pageOutcome"] as? [String: String] ==
            ["pageID": id, "outcome": "pending"])
        #expect(call(elisPageOutcomeSubmit(id, "yes"))["ok"] as? Bool == true)
        elisPageOutcomeDismiss(id)
        let outcome = (call(elisPageOutcomeResult(id))["result"] as? [String: Any])?["pageOutcome"] as? [String: String]
        #expect(outcome == ["pageID": id, "outcome": "submitted", "value": "yes"])
        #expect(call(elisPageOutcomeResult("nope"))["error"] as? String == OverlayHtmlError.invalidPageID)
        #expect(call(elisPageOutcomeResult(UUID().uuidString))["error"] as? String == OverlayHtmlError.unknownPage)
    }

    @Test func bridgeScriptsAreTheSharedOnes() {
        let scripts = call(elisHtmlBridgeScripts("window.webkit.messageHandlers.elis"))
        #expect(scripts["adapter"] as? String == HtmlBridgeAdapter.script(handler: "window.webkit.messageHandlers.elis"))
        #expect(scripts["helper"] as? String == HtmlBridgeAdapter.helperScript(handler: "window.webkit.messageHandlers.elis"))
    }

    private func bridged(_ message: [String: Any], pane: String? = nil) -> [String: Any] {
        var place: [String: Any] = ["session": "a1b2c3d4e5f6", "window": "w1"]
        if let pane { place["pane"] = pane }
        return call(elisHtmlBridgeRequest(json(message), json(place)))
    }

    @Test func aBridgedRequestIsFilledFromThePage() {
        let rename = bridged(["cmd": "session.rename", "args": ["name": "x"]])["request"] as? [String: Any]
        #expect(rename?["target"] as? String == "a1b2c3d4e5f6")
        #expect((rename?["args"] as? [String: Any])?["name"] as? String == "x")
        let reload = bridged(["cmd": "session.overlay.reload"], pane: "right")["request"] as? [String: Any]
        #expect(reload?["target"] as? String == "a1b2c3d4e5f6")
        let reloadArgs = reload?["args"] as? [String: Any]
        #expect(reloadArgs?["current"] as? Bool == true)
        #expect(reloadArgs?["pane"] as? String == "right")
        #expect((bridged(["cmd": "window.close"])["request"] as? [String: Any])?["target"] as? String == "w1")
        let tree = bridged(["cmd": "tree"])["request"] as? [String: Any]
        #expect((tree?["args"] as? [String: Any])?["window"] as? String == "w1")
        #expect((bridged(["cmd": "session.select", "target": "ffff"])["request"] as? [String: Any])?["target"] as? String == "ffff")
    }

    @Test func refusedCommandsAreTheMacs() {
        for cmd in ["zmx.present", "catalog.subscribe", "session.overlay.job.run", "session.overlay.page.serve", "zmx.reset",
                    "session.companion.page.attach", "session.attach", "phone.status", "phone.enable", "session.upload"] {
            #expect(bridged(["cmd": cmd])["error"] as? String == "\(cmd) cannot be sent from a page")
        }
        #expect((bridged(["cmd": "no.such"])["error"] as? String)?.hasPrefix("invalid request: ") == true)
    }
}
