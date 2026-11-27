import Foundation
import Testing
@testable import ElisCore

struct LogTailTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let bytes: [UInt8]
        let fromFileStart: Bool
        let maxLines: Int
        let expected: LogTail.Snapshot?

        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "whole file", bytes: Array("a\nb\n".utf8), fromFileStart: true, maxLines: 10,
             expected: .init(text: "a\nb\n", lines: 2, clipped: false)),
        Case(name: "partial first line dropped", bytes: Array("xx\na\nb\n".utf8), fromFileStart: false, maxLines: 10,
             expected: .init(text: "a\nb\n", lines: 2, clipped: false)),
        Case(name: "window starting on a line boundary keeps that line", bytes: Array("\na\nb\n".utf8), fromFileStart: false,
             maxLines: 10, expected: .init(text: "a\nb\n", lines: 2, clipped: false)),
        Case(name: "no LF in the window keeps the clipped line", bytes: Array("tail of a line".utf8), fromFileStart: false,
             maxLines: 10, expected: .init(text: "tail of a line", lines: 1, clipped: true)),
        Case(name: "line longer than the window ending in LF at its last byte", bytes: Array("end of a long line\n".utf8),
             fromFileStart: false, maxLines: 10, expected: .init(text: "end of a long line\n", lines: 1, clipped: true)),
        Case(name: "clipped line starts at a whole character", bytes: [0xA9] + Array("é line".utf8), fromFileStart: false,
             maxLines: 10, expected: .init(text: "é line", lines: 1, clipped: true)),
        Case(name: "trailing partial character left for the next read", bytes: Array("a\nb".utf8) + [0xC3], fromFileStart: true,
             maxLines: 10, expected: .init(text: "a\nb", lines: 2, clipped: false)),
        Case(name: "trailing partial four-byte character", bytes: Array("a\n".utf8) + [0xF0, 0x9F, 0x98], fromFileStart: true,
             maxLines: 10, expected: .init(text: "a\n", lines: 1, clipped: false)),
        Case(name: "trailing partial three-byte character", bytes: Array("a\n".utf8) + [0xE2, 0x82], fromFileStart: true,
             maxLines: 10, expected: .init(text: "a\n", lines: 1, clipped: false)),
        Case(name: "trailing C0 never starts a character", bytes: [0x61, 0xC0], fromFileStart: true, maxLines: 10, expected: nil),
        Case(name: "trailing F5 never starts a character", bytes: [0x61, 0xF5, 0x80], fromFileStart: true, maxLines: 10,
             expected: nil),
        Case(name: "trailing E0 80 is already invalid", bytes: [0x61, 0xE0, 0x80], fromFileStart: true, maxLines: 10,
             expected: nil),
        Case(name: "trailing ED A0 is a surrogate", bytes: [0x61, 0xED, 0xA0], fromFileStart: true, maxLines: 10, expected: nil),
        Case(name: "trailing F4 90 is past the last scalar", bytes: [0x61, 0xF4, 0x90], fromFileStart: true, maxLines: 10,
             expected: nil),
        Case(name: "final line without LF counts", bytes: Array("a\nb".utf8), fromFileStart: true, maxLines: 10,
             expected: .init(text: "a\nb", lines: 2, clipped: false)),
        Case(name: "only the last maxLines lines", bytes: Array("1\n2\n3\n4\n".utf8), fromFileStart: true, maxLines: 2,
             expected: .init(text: "3\n4\n", lines: 2, clipped: false)),
        Case(name: "CRLF counts the same lines and keeps the CR", bytes: Array("a\r\nb\r\n".utf8), fromFileStart: true,
             maxLines: 10, expected: .init(text: "a\r\nb\r\n", lines: 2, clipped: false)),
        Case(name: "empty data", bytes: [], fromFileStart: false, maxLines: 10, expected: .init(text: "", lines: 0, clipped: false)),
        Case(name: "NUL in a dropped line is not binary", bytes: Array("a\u{0}b\n".utf8) + Array("c\nd\n".utf8),
             fromFileStart: true, maxLines: 2, expected: .init(text: "c\nd\n", lines: 2, clipped: false)),
        Case(name: "truncation hole ahead of the first line is dropped", bytes: [0, 0, 0] + Array("new\n".utf8),
             fromFileStart: true, maxLines: 10, expected: .init(text: "new\n", lines: 1, clipped: false)),
        Case(name: "a window of nothing but NUL stays binary", bytes: [0, 0, 0, 0], fromFileStart: true, maxLines: 10, expected: nil),
        Case(name: "a hole followed only by more NUL after a line feed stays binary", bytes: [0, 0] + Array("\n".utf8) + [0],
             fromFileStart: true, maxLines: 10, expected: nil),
        Case(name: "a NUL inside a kept line stays binary", bytes: Array("ok\nbad\u{0}line\n".utf8), fromFileStart: true,
             maxLines: 10, expected: nil),
        Case(name: "NUL marks binary", bytes: Array("a\n".utf8) + [0] + Array("b\n".utf8), fromFileStart: true, maxLines: 10,
             expected: nil),
        Case(name: "invalid UTF-8 marks binary", bytes: Array("a\n".utf8) + [0xFF, 0xFE] + Array("b\n".utf8), fromFileStart: true,
             maxLines: 10, expected: nil),
    ]

    @Test(arguments: cases)
    func snapshotKeepsTheLastWholeLines(_ testCase: Case) {
        let snapshot = LogTail.snapshot(Data(testCase.bytes), offset: testCase.fromFileStart ? 0 : 100, maxLines: testCase.maxLines)

        #expect(snapshot.map { LogTail.Snapshot(text: $0.text, lines: $0.lines, clipped: $0.clipped) } == testCase.expected)
    }

    struct OffsetCase: Sendable, CustomTestStringConvertible {
        let name: String
        let bytes: [UInt8]
        let offset: Int
        let maxLines: Int
        let start: Int

        var testDescription: String { name }
    }

    static let offsetCases: [OffsetCase] = [
        OffsetCase(name: "whole file starts at zero", bytes: Array("a\nb\n".utf8), offset: 0, maxLines: 10, start: 0),
        OffsetCase(name: "the partial first line is past the start", bytes: Array("xx\na\nb\n".utf8), offset: 40, maxLines: 10, start: 43),
        OffsetCase(name: "a window on a line boundary starts after the byte before it", bytes: Array("\na\n".utf8), offset: 40,
                   maxLines: 10, start: 41),
        OffsetCase(name: "the line cap moves the start", bytes: Array("1\n2\n3\n".utf8), offset: 0, maxLines: 1, start: 4),
        OffsetCase(name: "a clipped line starts at its first whole character", bytes: [0xA9] + Array("é line".utf8), offset: 40,
                   maxLines: 10, start: 41),
        OffsetCase(name: "a trimmed unfinished character leaves the start alone", bytes: Array("xx\na\nb".utf8) + [0xC3], offset: 40,
                   maxLines: 10, start: 43),
        OffsetCase(name: "a dropped NUL hole moves the start", bytes: [0, 0] + Array("new\n".utf8), offset: 0, maxLines: 10, start: 2),
    ]

    @Test(arguments: offsetCases)
    func startOffsetIsTheFilePositionOfTheFirstShownByte(_ testCase: OffsetCase) throws {
        let snapshot = try #require(LogTail.snapshot(Data(testCase.bytes), offset: testCase.offset, maxLines: testCase.maxLines))

        #expect(snapshot.startOffset == testCase.start)
    }

    private func stamp(inode: UInt64 = 7, size: Int) -> BoundedFile.FileStamp {
        BoundedFile.FileStamp(device: 1, inode: inode, size: size, modifiedSeconds: size, modifiedNanoseconds: 0)
    }

    @Test func aShiftCountsTheLinesThatLeftTheFrontOfOneFile() {
        let old = LogTail.Snapshot(text: "a\nb\nc\n", lines: 3, clipped: false, startOffset: 10)
        let appended = LogTail.Snapshot(text: "a\nb\nc\nd\n", lines: 4, clipped: false, startOffset: 10)
        let evicted = LogTail.Snapshot(text: "c\nd\ne\n", lines: 3, clipped: false, startOffset: 14)
        let inside = LogTail.Snapshot(text: "\nd\n", lines: 2, clipped: true, startOffset: 15)
        let past = LogTail.Snapshot(text: "x\n", lines: 1, clipped: false, startOffset: 40)

        #expect(LogTail.shift(from: old, stamp: stamp(size: 16), to: old, stamp: stamp(size: 16)) == LogTail.Shift())
        #expect(LogTail.shift(from: old, stamp: stamp(size: 16), to: appended, stamp: stamp(size: 18)) == LogTail.Shift())
        #expect(LogTail.shift(from: old, stamp: stamp(size: 16), to: evicted, stamp: stamp(size: 20)) == LogTail.Shift(dropped: 2))
        #expect(LogTail.shift(from: old, stamp: stamp(size: 16), to: inside, stamp: stamp(size: 20)) == LogTail.Shift(dropped: 2, cut: true))
        #expect(LogTail.shift(from: old, stamp: stamp(size: 16), to: past, stamp: stamp(size: 42)) == LogTail.Shift(dropped: 3))
    }

    @Test func aShiftCountsCRLFAndALoneCRAsOneBreakEach() {
        let lone = LogTail.Snapshot(text: "a\rb\nc\n", lines: 2, clipped: false, startOffset: 0)
        let crlf = LogTail.Snapshot(text: "a\r\nb\n", lines: 2, clipped: false, startOffset: 0)
        let progress = LogTail.Snapshot(text: "a\rb\rc", lines: 1, clipped: false, startOffset: 0)
        let after = { (start: Int) in LogTail.Snapshot(text: "z\n", lines: 1, clipped: false, startOffset: start) }

        #expect(LogTail.shift(from: lone, stamp: stamp(size: 6), to: after(2), stamp: stamp(size: 8)) == LogTail.Shift(dropped: 1))
        #expect(LogTail.shift(from: crlf, stamp: stamp(size: 5), to: after(3), stamp: stamp(size: 7)) == LogTail.Shift(dropped: 1))
        #expect(LogTail.shift(from: crlf, stamp: stamp(size: 5), to: after(2), stamp: stamp(size: 7)) == LogTail.Shift(dropped: 0, cut: true))
        #expect(LogTail.shift(from: progress, stamp: stamp(size: 5), to: after(9), stamp: stamp(size: 11)) == LogTail.Shift(dropped: 3))
    }

    @Test func aShiftCallsAnotherFileOrAShrunkOneAReplacement() {
        let old = LogTail.Snapshot(text: "a\nb\n", lines: 2, clipped: false, startOffset: 10)
        let new = LogTail.Snapshot(text: "c\n", lines: 1, clipped: false, startOffset: 0)
        let later = LogTail.Snapshot(text: "b\nc\n", lines: 2, clipped: false, startOffset: 12)

        #expect(LogTail.shift(from: old, stamp: stamp(size: 14), to: later, stamp: stamp(inode: 8, size: 16)) == LogTail.Shift(replaced: true))
        #expect(LogTail.shift(from: old, stamp: stamp(size: 14), to: new, stamp: stamp(size: 2)) == LogTail.Shift(replaced: true))
        #expect(LogTail.shift(from: old, stamp: nil, to: later, stamp: stamp(size: 16)) == LogTail.Shift(replaced: true))
    }
}
