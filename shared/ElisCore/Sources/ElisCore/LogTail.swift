import Foundation

/// LogTail turns the bytes read from a log's end into the text a log page shows.
public enum LogTail {
    /// Snapshot is the shown text, its line count, whether its first line is the clipped end of a line longer
    /// than the read window, and `startOffset`, the file offset of the text's first byte.
    public struct Snapshot: Equatable, Sendable {
        public let text: String
        public let lines: Int
        public let clipped: Bool
        public let startOffset: Int

        public init(text: String, lines: Int, clipped: Bool, startOffset: Int = 0) {
            self.text = text
            self.lines = lines
            self.clipped = clipped
            self.startOffset = startOffset
        }
    }

    private static let lineFeed: UInt8 = 0x0A

    /// snapshot keeps the last `maxLines` whole lines of `data`, read from file offset `offset`. A read that did not
    /// start at the file's start begins one byte before its window, so a window opening on a line boundary keeps that line; the partial
    /// line ahead of the first LF is dropped, unless nothing follows that LF, when the one line longer than the
    /// window is kept from its first whole character and marked clipped. An unfinished character at the end
    /// is left for the next read. nil for a NUL byte or invalid UTF-8 in the kept lines, which mark binary data.
    public static func snapshot(_ data: Data, offset: Int, maxLines: Int) -> Snapshot? {
        var bytes = [UInt8](data)
        var clipped = false
        if offset > 0, !bytes.isEmpty {
            if let feed = bytes.firstIndex(of: lineFeed), feed < bytes.count - 1 {
                bytes.removeFirst(feed + 1)
            } else {
                bytes.removeFirst(bytes.prefix { isContinuation($0) }.count)
                clipped = !bytes.isEmpty
            }
        }
        let unfinished = unfinishedTail(bytes)
        bytes.removeLast(unfinished)
        // a writer still at its old offset after copytruncate leaves a hole of NUL bytes ahead of the new text
        let hole = bytes.prefix { $0 == 0 }.count
        if hole > 0, hole < bytes.count { bytes.removeFirst(hole) }

        let feeds = bytes.indices.filter { bytes[$0] == lineFeed }
        let total = feeds.count + (bytes.last.map { $0 == lineFeed ? 0 : 1 } ?? 0)
        let keep = max(0, maxLines)
        if total > keep {
            let drop = total - keep
            bytes = drop <= feeds.count ? Array(bytes[(feeds[drop - 1] + 1)...]) : []
            clipped = false
        }
        guard !bytes.contains(0), let text = String(bytes: bytes, encoding: .utf8) else { return nil }
        // the unfinished character is the only cut at the end, so every other missing byte was cut at the front
        let start = offset + data.count - unfinished - bytes.count
        return Snapshot(text: text, lines: min(total, keep), clipped: clipped, startOffset: start)
    }

    private static func isContinuation(_ byte: UInt8) -> Bool { byte & 0xC0 == 0x80 }

    // the count of trailing bytes that are a valid prefix of a character the read cut short; a complete or
    // malformed ending counts 0, leaving the decode to judge it
    private static func unfinishedTail(_ bytes: [UInt8]) -> Int {
        let tail = bytes.suffix(3)
        guard let lead = tail.lastIndex(where: { !isContinuation($0) }) else { return 0 }
        let present = bytes.count - lead
        let needed: Int
        var second: ClosedRange<UInt8> = 0x80...0xBF
        switch bytes[lead] {
        case 0xC2...0xDF: needed = 2
        case 0xE0: needed = 3; second = 0xA0...0xBF
        case 0xED: needed = 3; second = 0x80...0x9F
        case 0xE1...0xEF: needed = 3
        case 0xF0: needed = 4; second = 0x90...0xBF
        case 0xF4: needed = 4; second = 0x80...0x8F
        case 0xF1...0xF3: needed = 4
        default: return 0
        }
        guard present < needed else { return 0 }
        if present > 1, !second.contains(bytes[lead + 1]) { return 0 }
        return present
    }
}

extension LogTail {
    /// Shift is how the text a log page's push carries relates to what the page shows: `dropped` lines left its front,
    /// `cut` when the new start falls inside a line, `replaced` when the file is not the one the page's text came from.
    public struct Shift: Equatable, Sendable {
        public var dropped: Int
        public var cut: Bool
        public var replaced: Bool

        public init(dropped: Int = 0, cut: Bool = false, replaced: Bool = false) {
            self.dropped = dropped
            self.cut = cut
            self.replaced = replaced
        }
    }

    /// shift compares two snapshots of one file by their start offsets, counting the line feeds in the bytes the
    /// newer one no longer shows; another file, a shrunk one or a start that moved back is a replacement.
    public static func shift(from old: Snapshot?, stamp oldStamp: BoundedFile.FileStamp?, to new: Snapshot?,
                             stamp newStamp: BoundedFile.FileStamp?) -> Shift {
        guard let old, let new, old != new || oldStamp != newStamp else { return Shift() }
        guard let oldStamp, let newStamp, oldStamp.device == newStamp.device, oldStamp.inode == newStamp.inode,
              newStamp.size >= oldStamp.size, new.startOffset >= old.startOffset else { return Shift(replaced: true) }
        let bytes = Array(old.text.utf8)
        let gone = min(new.startOffset - old.startOffset, bytes.count)
        guard gone < bytes.count else {
            let unterminated = bytes.last.map { $0 != lineFeed && $0 != carriageReturn } ?? false
            return Shift(dropped: lineBreaks(bytes, before: bytes.count) + (unterminated ? 1 : 0))
        }
        return Shift(dropped: lineBreaks(bytes, before: gone), cut: gone > 0 && !breakEnds(bytes, at: gone))
    }

    private static let carriageReturn: UInt8 = 0x0D

    // LF, CRLF and a lone CR are each one break, as the page counts lines once it normalizes them
    private static func lineBreaks(_ bytes: [UInt8], before end: Int) -> Int {
        (0..<end).reduce(0) { $0 + (bytes[$1] == lineFeed || isLoneCR(bytes, $1) ? 1 : 0) }
    }

    private static func breakEnds(_ bytes: [UInt8], at index: Int) -> Bool {
        bytes[index - 1] == lineFeed || isLoneCR(bytes, index - 1)
    }

    private static func isLoneCR(_ bytes: [UInt8], _ index: Int) -> Bool {
        bytes[index] == carriageReturn && (index + 1 == bytes.count || bytes[index + 1] != lineFeed)
    }
}
