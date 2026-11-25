import SwiftUI

/// AssistantMarkdown draws an answer's markdown as blocks: `Text` keeps inline styles but runs every block
/// of a parsed `AttributedString` together, so paragraphs, list items and code blocks are split out here.
struct AssistantMarkdown: View {
    let text: String

    struct Block: Identifiable {
        enum Kind: Equatable { case paragraph, header, code, item(String) }
        let id: Int
        let kind: Kind
        /// list is the identity of the list an item belongs to; consecutive items of one list sit closer.
        let list: Int?
        let content: AttributedString
    }

    var body: some View {
        let blocks = Self.blocks(text)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(blocks) { block in
                view(block)
                    .padding(.bottom, spacing(after: block, in: blocks))
            }
        }
    }

    private func spacing(after block: Block, in blocks: [Block]) -> CGFloat {
        guard block.id + 1 < blocks.count else { return 0 }
        let next = blocks[block.id + 1]
        return block.list != nil && block.list == next.list ? 4 : 8
    }

    @ViewBuilder private func view(_ block: Block) -> some View {
        switch block.kind {
        case .paragraph:
            line(Text(block.content))
        case .header:
            line(Text(block.content).fontWeight(.semibold))
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
                line(Text(block.content))
            }
        }
    }

    private func line(_ text: Text) -> some View {
        text.font(.system(size: 13))
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
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
