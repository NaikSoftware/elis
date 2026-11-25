import ElisCore
import SwiftUI

/// AssistantMarkdown draws an answer's markdown as blocks: `Text` keeps inline styles but runs every block
/// of a parsed `AttributedString` together, so paragraphs, list items and code blocks are split out here.
struct AssistantMarkdown: View {
    let text: String
    var directory = AssistantDirectory([])
    var dark = false

    struct Block: Identifiable {
        enum Kind: Equatable { case paragraph, header, code, item(String) }
        let id: Int
        let kind: Kind
        /// list is the identity of the list an item belongs to; consecutive items of one list sit closer.
        let list: Int?
        let content: AttributedString
    }

    var body: some View {
        let marked = Self.mark(text, in: directory)
        let blocks = Self.blocks(marked.source)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(blocks) { block in
                view(block, mentions: marked.mentions)
                    .padding(.bottom, spacing(after: block, in: blocks))
            }
        }
        // provider and session text is untrusted: a link opens only through the terminal's web/mail allowlist
        .environment(\.openURL, Self.openURL)
    }

    static let openURL = OpenURLAction { opens($0) ? .systemAction($0) : .discarded }

    static func opens(_ url: URL) -> Bool { LinkPolicy.permittedSchemes.contains(url.scheme?.lowercased() ?? "") }

    private func spacing(after block: Block, in blocks: [Block]) -> CGFloat {
        guard block.id + 1 < blocks.count else { return 0 }
        let next = blocks[block.id + 1]
        return block.list != nil && block.list == next.list ? 4 : 8
    }

    @ViewBuilder private func view(_ block: Block, mentions: [AssistantMentionSegment]) -> some View {
        let content = Self.text(block.content, mentions: mentions, dark: dark)
        switch block.kind {
        case .paragraph:
            line(content)
        case .header:
            line(content.fontWeight(.semibold))
        case .code:
            Text(block.content)
                .font(.system(size: 12, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 6))
        case .item(let marker):
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(verbatim: marker).font(.system(size: 13)).frame(width: 18, alignment: .leading)
                line(content)
            }
        }
    }

    private func line(_ text: Text) -> some View {
        text.font(.system(size: 13))
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Mentions

    private static let open: Character = "\u{E000}", close: Character = "\u{E001}"

    /// mark swaps each session an answer names for a private-use placeholder that markdown parsing leaves alone.
    static func mark(_ text: String, in directory: AssistantDirectory) -> (source: String, mentions: [AssistantMentionSegment]) {
        var source = "", mentions: [AssistantMentionSegment] = []
        for segment in AssistantMentions.segments(text, in: directory) {
            guard case .text(let plain) = segment else {
                source += "\(open)\(mentions.count)\(close)"
                mentions.append(segment)
                continue
            }
            source += plain
        }
        return (source, mentions)
    }

    /// An error line: no markdown, but its sessions named as in an answer.
    static func plain(_ text: String, in directory: AssistantDirectory, dark: Bool) -> Text {
        let marked = mark(text, in: directory)
        return self.text(AttributedString(marked.source), mentions: marked.mentions, dark: dark)
    }

    /// text joins a block's runs and its mentions' chips, which `Text` can only hold as images.
    static func text(_ content: AttributedString, mentions: [AssistantMentionSegment], dark: Bool) -> Text {
        var result = Text(verbatim: "")
        var rest = content[content.startIndex..<content.endIndex]
        while let start = rest.characters.firstIndex(of: open), let end = rest.characters[start...].firstIndex(of: close) {
            let index = Int(String(rest.characters[rest.characters.index(after: start)..<end])) ?? -1
            result = Text("\(result)\(Text(AttributedString(rest[rest.startIndex..<start])))\(mention(index, in: mentions, dark: dark))")
            rest = rest[rest.characters.index(after: end)..<rest.endIndex]
        }
        return Text("\(result)\(Text(AttributedString(rest)))")
    }

    private static func mention(_ index: Int, in mentions: [AssistantMentionSegment], dark: Bool) -> Text {
        guard mentions.indices.contains(index), case .mention(_, let handle) = mentions[index] else { return Text(verbatim: "") }
        // a session that ended has no tag to show, as its cards say
        guard let handle else { return Text(verbatim: "ended session") }
        return Text(Image(nsImage: AssistantTagStyle.chipImage("@\(handle)", dark: dark))).baselineOffset(-4.5)
    }

    static func blocks(_ source: String) -> [Block] {
        guard var parsed = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .full)) else {
            return [Block(id: 0, kind: .paragraph, list: nil, content: AttributedString(source))]
        }
        for run in parsed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            parsed[run.range].swiftUI.font = .system(size: 12, design: .monospaced)
            parsed[run.range].swiftUI.backgroundColor = Color.primary.opacity(0.065)
        }
        var blocks: [Block] = []
        var current: (intent: PresentationIntent?, content: AttributedString)?
        func flush() {
            guard let current else { return }
            blocks.append(block(id: blocks.count, intent: current.intent, content: current.content))
        }
        for run in parsed.runs {
            let intent = run.presentationIntent
            if current?.intent != intent {
                flush()
                current = (intent, AttributedString())
            }
            current?.content.append(parsed[run.range])
        }
        flush()
        return blocks
    }

    private static func block(id: Int, intent: PresentationIntent?, content: AttributedString) -> Block {
        let components = intent?.components ?? []
        var trimmed = content
        while trimmed.characters.last?.isNewline == true { trimmed.characters.removeLast() }
        for component in components {
            switch component.kind {
            case .codeBlock: return Block(id: id, kind: .code, list: nil, content: trimmed)
            case .header: return Block(id: id, kind: .header, list: nil, content: trimmed)
            case .listItem(let ordinal):
                let list = components.first { [.orderedList, .unorderedList].contains($0.kind) }
                let marker = list?.kind == .orderedList ? "\(ordinal)." : "•"
                return Block(id: id, kind: .item(marker), list: list?.identity, content: trimmed)
            default: continue
            }
        }
        return Block(id: id, kind: .paragraph, list: nil, content: trimmed)
    }
}
