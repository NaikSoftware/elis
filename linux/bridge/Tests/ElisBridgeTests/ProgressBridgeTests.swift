import ElisBridge
import Foundation
import Testing

private func call(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
    guard let pointer else { return "<nil>" }
    defer { free(pointer) }
    return String(cString: pointer)
}

private func json(_ text: String) -> NSObject? {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)) as? NSObject
}

private func parse(_ text: String) -> String { call(elisProgressParse(text)) }
private func terminal(_ body: String) -> String { call(elisProgressTerminal(body)) }
private func row(_ input: String) -> String { call(elisProgressRow(input)) }

@Suite struct ProgressBridgeTests {
    @Test func parseShapes() {
        #expect(json(parse("3/7")) == json(#"{"ok":true,"progress":{"done":3,"total":7}}"#))
        #expect(json(parse("40%")) == json(#"{"ok":true,"progress":{"percent":40}}"#))
        #expect(json(parse("indeterminate")) == json(#"{"ok":true,"progress":{"indeterminate":true}}"#))
        #expect(json(parse("clear")) == json(#"{"ok":true,"progress":null}"#))
        #expect(json(parse("8/7")) == json(#"{"ok":false,"error":"invalid progress"}"#))
    }

    @Test func terminalShapes() {
        #expect(json(terminal("4;1;40")) == json(#"{"update":"set","progress":{"percent":40}}"#))
        #expect(json(terminal("4;3")) == json(#"{"update":"set","progress":{"indeterminate":true}}"#))
        #expect(json(terminal("4;0")) == json(#"{"update":"clear"}"#))
        #expect(terminal("4;9;1") == "null")
        #expect(terminal("nonsense") == "null")
    }

    @Test func rowFillAndWave() {
        #expect(json(row(##"{"progress":{"percent":50},"status":"idle","sessionTint":"#336699","active":"#aa0000"}"##))
            == json(##"{"fill":{"color":"#336699","fraction":0.5,"alpha":0.22,"feather":26},"wave":false}"##))
        #expect(json(row(##"{"progress":{"percent":50},"status":"idle","workspaceTint":"#112233","active":"#aa0000"}"##))
            == json(##"{"fill":{"color":"#112233","fraction":0.5,"alpha":0.22,"feather":26},"wave":false}"##))
        #expect(json(row(##"{"progress":{"percent":50},"status":"blocked","active":"#aa0000"}"##))
            == json(##"{"fill":null,"wave":false}"##))
        #expect(json(row(##"{"progress":{"indeterminate":true},"status":"idle","active":"#aa0000"}"##))
            == json(##"{"fill":null,"wave":true}"##))
        #expect(json(row(##"{"status":"active","active":"#aa0000"}"##)) == json(##"{"fill":null,"wave":true}"##))
    }
}
