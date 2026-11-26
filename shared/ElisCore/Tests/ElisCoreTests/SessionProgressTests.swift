import Foundation
import Testing
@testable import ElisCore

struct SessionProgressTests {
    @Test(arguments: [("3/7", SessionProgress.steps(done: 3, total: 7)), ("0/1", .steps(done: 0, total: 1)),
                      ("40%", .percent(40)), ("100%", .percent(100)), ("indeterminate", .indeterminate),
                      (" 5/9\n", .steps(done: 5, total: 9))])
    func parsesEachForm(text: String, expected: SessionProgress) throws {
        #expect(try SessionProgress.parse(text) == expected)
    }

    @Test func clearParsesToNil() throws {
        #expect(try SessionProgress.parse("clear") == nil)
    }

    @Test(arguments: ["8/7", "1/0", "-1/3", "101%", "-1%", "40", "", "3/10001", "a/b", "3/7/9"])
    func refusesOutOfRange(text: String) {
        #expect(throws: SessionProgressError.invalid) { try SessionProgress.parse(text) }
    }

    @Test func errorReadsInvalidProgress() {
        #expect(SessionProgressError.invalid.description == "invalid progress")
    }

    @Test func fractionAndLabel() {
        #expect(SessionProgress.steps(done: 3, total: 7).fraction == 3.0 / 7)
        #expect(SessionProgress.percent(40).fraction == 0.4)
        #expect(SessionProgress.indeterminate.fraction == nil)
        #expect(SessionProgress.steps(done: 3, total: 7).label == "3/7")
        #expect(SessionProgress.percent(40).label == "40%")
        #expect(SessionProgress.indeterminate.label == "indeterminate")
    }

    @Test func terminalStatesMapLikeConEmu() {
        #expect(SessionProgress.terminal(state: 0, progress: -1) == .clear)
        #expect(SessionProgress.terminal(state: 1, progress: 40) == .set(.percent(40)))
        #expect(SessionProgress.terminal(state: 2, progress: 70) == .set(.percent(70)))
        #expect(SessionProgress.terminal(state: 4, progress: 10) == .set(.percent(10)))
        #expect(SessionProgress.terminal(state: 1, progress: -1) == .set(.indeterminate))
        #expect(SessionProgress.terminal(state: 1, progress: 101) == .set(.indeterminate))
        #expect(SessionProgress.terminal(state: 3, progress: 0) == .set(.indeterminate))
        #expect(SessionProgress.terminal(state: 9, progress: 0) == nil)
    }

    @Test func conEmuBodyParses() {
        #expect(SessionProgress.conEmu("4;1;40") == .set(.percent(40)))
        #expect(SessionProgress.conEmu("4;0") == .clear)
        #expect(SessionProgress.conEmu("4;3;") == .set(.indeterminate))
        #expect(SessionProgress.conEmu("4;1") == .set(.indeterminate))
        #expect(SessionProgress.conEmu("4;x;1") == nil)
        #expect(SessionProgress.conEmu("hello") == nil)
    }

    @Test func codingIsStable() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(String(decoding: try encoder.encode(SessionProgress.steps(done: 3, total: 7)), as: UTF8.self)
                == #"{"done":3,"total":7}"#)
        #expect(String(decoding: try encoder.encode(SessionProgress.percent(40)), as: UTF8.self) == #"{"percent":40}"#)
        #expect(String(decoding: try encoder.encode(SessionProgress.indeterminate), as: UTF8.self)
                == #"{"indeterminate":true}"#)
        for value in [SessionProgress.steps(done: 3, total: 7), .percent(40), .indeterminate] {
            #expect(try JSONDecoder().decode(SessionProgress.self, from: encoder.encode(value)) == value)
        }
    }
}
