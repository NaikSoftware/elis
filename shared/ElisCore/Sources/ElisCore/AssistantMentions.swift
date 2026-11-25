import Foundation

/// One piece of an assistant answer: plain text, or a session named by a reply frame or its id.
public enum AssistantMentionSegment: Equatable, Sendable {
    case text(String)
    /// handle is nil for a session that no longer exists.
    case mention(sessionID: String, handle: String?)
}

/// AssistantMentions finds the sessions an answer names, so a view shows them as tags instead of ids:
/// a `[reply from @<handle> <id>]` frame whatever its session's state, and a bare id of a live session outside a URL path.
public enum AssistantMentions {
    private static let uuid = "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
    private static let pattern = try! NSRegularExpression( // swiftlint:disable:this force_try
        pattern: #"\[reply from @[^\s\]]* ("# + uuid + #")\]|(?<!/)\b("# + uuid + #")\b"#)

    public static func segments(_ text: String, in directory: AssistantDirectory) -> [AssistantMentionSegment] {
        let known = Dictionary(directory.peers.map { ($0.sessionID.uppercased(), $0.sessionID) }) { first, _ in first }
        let source = text as NSString
        var segments: [AssistantMentionSegment] = []
        var cursor = 0
        func appendText(upTo end: Int) {
            if end > cursor { segments.append(.text(source.substring(with: NSRange(location: cursor, length: end - cursor)))) }
        }
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let framed = match.range(at: 1).location != NSNotFound
            let id = source.substring(with: match.range(at: framed ? 1 : 2))
            let sessionID = known[id.uppercased()]
            // an unknown bare id is just text; a frame always names a session, if only an ended one
            guard framed || sessionID != nil else { continue }
            appendText(upTo: match.range.location)
            segments.append(.mention(sessionID: sessionID ?? id, handle: sessionID.flatMap(directory.handle(of:))))
            cursor = NSMaxRange(match.range)
        }
        appendText(upTo: source.length)
        return segments
    }
}
