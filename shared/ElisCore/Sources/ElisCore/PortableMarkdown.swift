#if !canImport(Darwin) && canImport(Markdown)
import Foundation
import Markdown

// the attributed Markdown initializer is Darwin Foundation only; these Linux paths through swift-markdown cover
// what a headless origin checks: it validates and discovers, the Mac renders

/// MarkdownImageCollector lists every picture source in document order, for `MarkdownPage`.
struct MarkdownImageCollector: MarkupWalker {
    private(set) var sources: [String] = []

    static func sources(in markdown: String) -> [String] {
        var collector = MarkdownImageCollector()
        collector.visit(Document(parsing: markdown))
        return collector.sources
    }

    mutating func visitImage(_ image: Markdown.Image) {
        if let source = image.source { sources.append(source) }
        descendInto(image)
    }
}

extension HudMarkdown {
    /// paintsVisibleText reports a non-space cell after the renderer's own `sanitized`.
    static func paintsVisibleText(_ source: String) -> Bool {
        paints(Document(parsing: source.precomposedStringWithCanonicalMapping))
    }

    private static func paints(_ node: any Markup) -> Bool {
        let text: String?
        switch node {
        case is ThematicBreak: return true
        case let leaf as Markdown.Text: text = leaf.string
        case let code as InlineCode: text = code.code
        case let block as CodeBlock: text = block.code
        case let html as InlineHTML: text = html.rawHTML
        case let html as HTMLBlock: text = html.rawHTML
        default: text = nil
        }
        if let text {
            return sanitized(text).unicodeScalars.contains { !$0.properties.isWhitespace }
        }
        return node.children.contains { paints($0) }
    }
}
#endif
