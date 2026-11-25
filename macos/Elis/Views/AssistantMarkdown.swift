import ElisCore
import SwiftUI

/// AssistantMarkdown draws an answer's markdown as blocks: `Text` keeps inline styles but runs every block
/// of a parsed `AttributedString` together, so paragraphs, list items and code blocks are split out here.
struct AssistantMarkdown: View {
    let text: String
    var directory = AssistantDirectory([])

    struct Block: Identifiable {
        enum Kind: Equatable { case paragraph, header, code, item(String) }
        let id: Int
        let kind: Kind
        /// list is the identity of the list an item belongs to; consecutive items of one list sit closer.
        let list: Int?
        let content: AttributedString
    }

    var body: some View {
        let blocks = Self.blocks(text, in: directory)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(blocks) { block in
                view(block)
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

    @ViewBuilder private func view(_ block: Block) -> some View {
        let content = Self.text(block.content)
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
            .mentionChips()
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Mentions

    /// An error line: no markdown, but its sessions named as in an answer.
    static func plain(_ text: String, in directory: AssistantDirectory) -> Text {
        self.text(mentioning(AttributedString(text), in: directory))
    }

    /// text joins a block's runs and its mentions' tags; `mentionChips()` draws the chips behind the tags.
    static func text(_ content: AttributedString) -> Text {
        var result = Text(verbatim: "")
        for run in content.runs {
            let piece = run.assistantMention == nil ? Text(AttributedString(content[run.range]))
                : mention(String(content[run.range].characters))
            result = Text("\(result)\(piece)")
        }
        return result
    }

    /// mentioning swaps the sessions plain text names for their tags, after parsing, so code and link
    /// destinations keep their ids verbatim; a link's visible text keeps them too, since a tag inside a link reads as one.
    static func mentioning(_ parsed: AttributedString, in directory: AssistantDirectory) -> AttributedString {
        var result = AttributedString()
        for run in parsed.runs {
            let piece = AttributedString(parsed[run.range])
            let code = run.inlinePresentationIntent?.contains(.code) == true
                || run.presentationIntent?.components.contains { if case .codeBlock = $0.kind { true } else { false } } == true
            guard !code, run.link == nil else {
                result.append(piece)
                continue
            }
            for segment in AssistantMentions.segments(String(piece.characters), in: directory) {
                switch segment {
                case .text(let text):
                    result.append(AttributedString(text, attributes: run.attributes))
                case .mention(let id, let handle?):
                    var tag = AttributedString("@\(handle)", attributes: run.attributes)
                    tag.assistantMention = id
                    result.append(tag)
                case .mention(_, nil):
                    // a session that ended has no tag to show, as its cards say
                    result.append(AttributedString("ended session", attributes: run.attributes))
                }
            }
        }
        return result
    }

    /// The chip's padding: a 1pt-high image, so it widens the line without heightening it.
    private static let chipPad = Text(Image(nsImage: NSImage(size: NSSize(width: AssistantTagStyle.chipPad, height: 1))))

    private static func mention(_ tag: String) -> Text {
        let tag = Text(verbatim: tag).fontWeight(.medium)
        guard #available(macOS 15.0, *) else { return tag }
        return Text("\(chipPad)\(tag.customAttribute(MentionChip()))\(chipPad)")
    }

    static func blocks(_ source: String, in directory: AssistantDirectory = AssistantDirectory([])) -> [Block] {
        guard var parsed = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .full)) else {
            return [Block(id: 0, kind: .paragraph, list: nil, content: mentioning(AttributedString(source), in: directory))]
        }
        for run in parsed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            parsed[run.range].swiftUI.font = .system(size: 12, design: .monospaced)
            parsed[run.range].swiftUI.backgroundColor = Color.primary.opacity(0.065)
        }
        parsed = mentioning(parsed, in: directory)
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

extension View {
    /// mentionChips draws each tag's chip behind its text, as the composer does, so a line holding one keeps its
    /// height; an inline image would push the line. Before macOS 15 the tags show without a chip.
    @ViewBuilder func mentionChips() -> some View {
        if #available(macOS 15.0, *) {
            textRenderer(MentionChipRenderer(fill: Color(nsColor: .controlAccentColor).opacity(0.25), pad: AssistantTagStyle.chipPad))
        } else {
            self
        }
    }
}

@available(macOS 15.0, *)
private struct MentionChip: TextAttribute {}

@available(macOS 15.0, *)
private struct MentionChipRenderer: TextRenderer {
    let fill: Color
    let pad: CGFloat

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                if run[MentionChip.self] != nil {
                    let text = run.typographicBounds.rect
                    let chip = CGRect(x: text.minX - pad, y: text.midY - 9.5, width: text.width + pad * 2, height: 19)
                    context.fill(RoundedRectangle(cornerRadius: 5).path(in: chip), with: .color(fill))
                }
                context.draw(run)
            }
        }
    }
}

/// AssistantMentionKey marks the text standing for a session an answer names; its value is the session id.
enum AssistantMentionKey: AttributedStringKey {
    typealias Value = String
    static let name = "ElisAssistantMention"
}

extension AttributeScopes {
    struct AssistantAttributes: AttributeScope {
        let assistantMention: AssistantMentionKey
    }
}

extension AttributeDynamicLookup {
    subscript<T: AttributedStringKey>(dynamicMember keyPath: KeyPath<AttributeScopes.AssistantAttributes, T>) -> T {
        self[T.self]
    }
}
