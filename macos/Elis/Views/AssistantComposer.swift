import AppKit
import ElisCore
import SwiftUI

/// One `@` completion row: a tag, the name it stands for, and its icon.
struct AssistantCompletionRow: Identifiable, Equatable {
    enum Icon: Equatable { case all, workspace, session(SessionLauncher?) }

    let tag: String
    let name: String
    let icon: Icon
    var id: String { tag }
}

/// AssistantComposerState is what the composer's AppKit text view shares with the SwiftUI chrome around it.
@MainActor
@Observable
final class AssistantComposerState {
    var text = ""
    var lines = 1
    var dropping = false
    var focused = false
    var completion: [AssistantCompletionRow] = []
    var highlighted = 0
    /// completionX is the `@` token's leading edge in the text view, where the completion panel starts.
    var completionX: CGFloat = 0
    @ObservationIgnored weak var textView: AssistantComposerTextView?
}

/// AssistantComposer hosts the composer's text view, sized by `state.lines`.
struct AssistantComposer: NSViewRepresentable {
    let model: AssistantModel
    let store: AppStore
    let state: AssistantComposerState

    func makeNSView(context _: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let textView = AssistantComposerTextView(model: model, store: store, state: state)
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_: NSScrollView, context _: Context) {}
}

/// The composer's text: tags drawn as chips in place, `@` completion, sidebar-row drops, Return to send.
final class AssistantComposerTextView: NSTextView {
    static let lineHeight: CGFloat = 22
    static let maxLines = 8
    static let placeholder = "Message Elis…  @ to tag, or drag a row from the sidebar"
    private static let tokenPattern = try! NSRegularExpression(pattern: #"(?:^|\s)(@[^\s@]*)$"#) // swiftlint:disable:this force_try

    let model: AssistantModel
    let store: AppStore
    let state: AssistantComposerState
    private var known: Set<String> = []

    init(model: AssistantModel, store: AppStore, state: AssistantComposerState) {
        self.model = model
        self.store = store
        self.state = state
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 2
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        state.textView = self
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        drawsBackground = false
        isVerticallyResizable = true
        textContainerInset = .zero
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        font = AssistantTagStyle.font
        typingAttributes = Self.baseAttributes
        updateDragTypeRegistration()
        setAccessibilityIdentifier("assistant-composer")
        setAccessibilityPlaceholderValue(Self.placeholder)
        NotificationCenter.default.addObserver(self, selector: #selector(focusRequested), name: .elisFocusAssistantComposer, object: store)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    private static let baseAttributes = AssistantTagStyle.attributes(lineHeight: lineHeight)

    // MARK: - Focus

    @objc private func focusRequested() { takeFocus() }

    func takeFocus() {
        guard model.mayFocus(store) else { return }
        window?.makeFirstResponder(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        refreshKnown()
        // the chat mounts after showAssistant posted its focus request
        DispatchQueue.main.async { [weak self] in self?.takeFocus() }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { state.focused = true }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            state.focused = false
            closeCompletion()
        }
        return resigned
    }

    // MARK: - Keys

    override func keyDown(with event: NSEvent) {
        guard !hasMarkedText() else { return super.keyDown(with: event) }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let completing = !state.completion.isEmpty
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, mods == .shift {
            insertText("\n", replacementRange: selectedRange())
        } else if isReturn, mods.isEmpty {
            if completing { acceptCompletion() } else { send() }
        } else if completing, event.keyCode == 48, mods.isEmpty {
            acceptCompletion()
        } else if completing, event.keyCode == 125 || event.keyCode == 126 {
            moveCompletion(event.keyCode == 125 ? 1 : -1)
        } else {
            super.keyDown(with: event)
        }
    }

    // the next key view can be a hidden deck surface, so Tab never leaves the field
    override func insertTab(_: Any?) {}

    override func insertBacktab(_: Any?) {}

    // Escape closes the completion and otherwise does nothing; NSTextView's own Escape opens word completion
    override func cancelOperation(_: Any?) {
        closeCompletion()
    }

    /// A Backspace right after a chip deletes the whole chip.
    override func deleteBackward(_ sender: Any?) {
        let selection = selectedRange()
        if selection.length == 0, let tag = tagRanges().first(where: { NSMaxRange($0) == selection.location }) {
            setSelectedRange(tag)
        }
        super.deleteBackward(sender)
    }

    func send() {
        let body = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        var args = ControlArgs()
        args.text = body
        let request = ControlRequest(cmd: .assistantAsk, args: args)
        Task { [weak self, model] in
            let response = await model.perform(request)
            // a refused message stays in the field, so nothing typed is lost
            guard response.ok, let self, self.string.trimmingCharacters(in: .whitespacesAndNewlines) == body else { return }
            self.replace(with: "")
        }
    }

    private func replace(with text: String) {
        string = text
        // undoing the sent text's typing would edit text that is gone; NSTextView registers it on private targets
        undoManager?.removeAllActions()
        didChangeText()
    }

    // MARK: - Edits, tags and completion

    override func didChangeText() {
        super.didChangeText()
        store.noteUserActivity()
        state.text = string
        refreshKnown()
        updateCompletion()
        updateLines()
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if !stillSelecting, !state.completion.isEmpty { updateCompletion() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateLines()
    }

    private var directory: AssistantDirectory { model.directory() }

    private func refreshKnown() {
        known = AssistantTagStyle.knownTags(directory)
        restyle()
    }

    /// The ranges of the words that name a session, a workspace or `@all`.
    func tagRanges() -> [NSRange] { AssistantTagStyle.tagRanges(string, known: known) }

    private func restyle() {
        guard let textStorage, !hasMarkedText() else { return }
        AssistantTagStyle.apply(to: textStorage, known: known, lineHeight: Self.lineHeight)
        typingAttributes = Self.baseAttributes
        needsDisplay = true
    }

    private func updateLines() {
        guard let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let used = max(Self.lineHeight, layoutManager.usedRect(for: textContainer).height)
        let lines = min(Self.maxLines, max(1, Int((used / Self.lineHeight).rounded())))
        if state.lines != lines { state.lines = lines }
    }

    /// The `@` word ending at the caret, in the whole text.
    private func tokenRange() -> NSRange? {
        let caret = selectedRange().location
        let text = string as NSString
        let lineStart = text.lineRange(for: NSRange(location: caret, length: 0)).location
        let before = text.substring(with: NSRange(location: lineStart, length: caret - lineStart))
        guard let match = Self.tokenPattern.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) else {
            return nil
        }
        return NSRange(location: lineStart + match.range(at: 1).location, length: match.range(at: 1).length)
    }

    /// Opens, filters or closes the completion for the `@` word ending at the caret.
    func updateCompletion() {
        guard selectedRange().length == 0, !hasMarkedText(), let token = tokenRange() else { return closeCompletion() }
        let prefix = (string as NSString).substring(with: token).lowercased()
        let rows = completionRows().filter { $0.tag.lowercased().hasPrefix(prefix) }
        guard !rows.isEmpty else { return closeCompletion() }
        if rows.map(\.tag) != state.completion.map(\.tag) { state.highlighted = 0 }
        state.completion = rows
        state.completionX = caretX(at: token.location)
    }

    private func caretX(at location: Int) -> CGFloat {
        guard let layoutManager, let textContainer else { return 0 }
        let glyph = layoutManager.glyphIndexForCharacter(at: location)
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 0), in: textContainer)
        return rect.minX + textContainerOrigin.x
    }

    /// The rows Linux offers, in its order: `@all`, then each workspace's tag followed by its sessions.
    func completionRows() -> [AssistantCompletionRow] {
        let directory = directory
        var rows = [AssistantCompletionRow(tag: "@all", name: "every agent session", icon: .all)]
        var workspace: String?
        for peer in directory.peers {
            if peer.workspaceID != workspace {
                workspace = peer.workspaceID
                if let handle = directory.workspaceHandle(of: peer.workspaceID) {
                    rows.append(AssistantCompletionRow(tag: "@ws:\(handle)", name: peer.workspaceName, icon: .workspace))
                }
            }
            guard let handle = directory.handle(of: peer.sessionID) else { continue }
            rows.append(AssistantCompletionRow(tag: "@\(handle)", name: peer.name,
                                               icon: .session(peer.agent.flatMap(SessionLauncher.init(rawValue:)))))
        }
        return rows
    }

    func closeCompletion() {
        if !state.completion.isEmpty { state.completion = [] }
    }

    private func moveCompletion(_ step: Int) {
        let count = state.completion.count
        state.highlighted = (state.highlighted + step + count) % count
    }

    func acceptCompletion(_ index: Int? = nil) {
        let rows = state.completion
        let index = index ?? state.highlighted
        guard rows.indices.contains(index), let token = tokenRange() else { return }
        closeCompletion()
        insertTags([rows[index].tag], replacing: token)
    }

    /// Inserts the tags with a space before them unless one is there, and one after them, so typing goes on.
    func insertTags(_ tags: [String], replacing range: NSRange) {
        guard !tags.isEmpty else { return }
        refreshKnown()
        let text = string as NSString
        let spaceBefore = range.location == 0 || CharacterSet.whitespacesAndNewlines
            .contains(Unicode.Scalar(text.character(at: range.location - 1)) ?? " ")
        let spaced = NSMaxRange(range) < text.length && text.character(at: NSMaxRange(range)) == 0x20
        let words = (spaceBefore ? "" : " ") + tags.joined(separator: " ") + (spaced ? "" : " ")
        insertText(words, replacementRange: range)
        if spaced { setSelectedRange(NSRange(location: selectedRange().location + 1, length: 0)) }
        closeCompletion()
    }

    // MARK: - Chips

    override func draw(_ dirtyRect: NSRect) {
        if string.isEmpty {
            let origin = NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0), y: textContainerOrigin.y)
            NSAttributedString(string: Self.placeholder, attributes: Self.baseAttributes.merging(
                [.foregroundColor: NSColor.placeholderTextColor]) { $1 })
                .draw(at: origin)
        }
        drawChips()
        super.draw(dirtyRect)
    }

    private func drawChips() {
        guard let layoutManager, let textContainer else { return }
        AssistantTagStyle.drawChips(tagRanges(), layoutManager: layoutManager, textContainer: textContainer,
                                    origin: textContainerOrigin, lineHeight: Self.lineHeight)
    }

    // MARK: - Sidebar drops

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + [sessionPasteboardType, workspacePasteboardType]
    }

    /// The tags a sidebar drag adds: nil for a drag that is not a sidebar row, empty for one with no local peer.
    func sidebarTags(_ pasteboard: NSPasteboard) -> [String]? {
        let types = pasteboard.types ?? []
        let directory = directory
        if types.contains(sessionPasteboardType) {
            let strings = pasteboard.pasteboardItems?.compactMap { $0.string(forType: sessionPasteboardType) } ?? []
            let ids = strings.flatMap { $0.split(whereSeparator: \.isNewline).map(String.init) }
            return ids.compactMap { id in directory.handle(of: id).map { "@\($0)" } }
        }
        if types.contains(workspacePasteboardType) {
            let id = pasteboard.string(forType: workspacePasteboardType) ?? ""
            return directory.workspaceHandle(of: id).map { ["@ws:\($0)"] } ?? []
        }
        return nil
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        sidebarDrag(sender) ?? super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        sidebarDrag(sender) ?? super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        state.dropping = false
        super.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        sidebarTags(sender.draggingPasteboard).map { !$0.isEmpty } ?? super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard sidebarTags(sender.draggingPasteboard) != nil else { return super.performDragOperation(sender) }
        return dropSidebarRow(sender, at: landing(sender))
    }

    /// Inserts a sidebar row's tags at `location`, or at the caret when the drop missed the text.
    func dropSidebarRow(_ sender: any NSDraggingInfo, at location: Int?) -> Bool {
        state.dropping = false
        guard let tags = sidebarTags(sender.draggingPasteboard), !tags.isEmpty else { return false }
        window?.makeFirstResponder(self)
        insertTags(tags, replacing: NSRange(location: location ?? selectedRange().location, length: 0))
        return true
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        guard let sender, sidebarTags(sender.draggingPasteboard) != nil else { return super.concludeDragOperation(sender) }
    }

    /// A sidebar row's operation, nil for any other drag; a sidebar row with no local peer is refused.
    func sidebarDrag(_ sender: any NSDraggingInfo) -> NSDragOperation? {
        guard let tags = sidebarTags(sender.draggingPasteboard) else { return nil }
        state.dropping = !tags.isEmpty
        return tags.isEmpty ? [] : .copy
    }

    /// The caret under the pointer, moved past the word it splits.
    private func landing(_ sender: any NSDraggingInfo) -> Int {
        let point = convert(sender.draggingLocation, from: nil)
        var at = min(characterIndexForInsertion(at: point), (string as NSString).length)
        let text = string as NSString
        let space = CharacterSet.whitespacesAndNewlines
        func isSpace(_ index: Int) -> Bool { Unicode.Scalar(text.character(at: index)).map(space.contains) ?? false }
        while at < text.length, at > 0, !isSpace(at - 1), !isSpace(at) { at += 1 }
        return at
    }
}

/// AssistantTagStyle draws tags as chips in an AppKit text view: the composer's and the user message's.
@MainActor
enum AssistantTagStyle {
    static let font = NSFont.systemFont(ofSize: 13)
    static let tagFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let chipPad: CGFloat = 5
    private static let pattern = try! NSRegularExpression(pattern: #"(?<!\S)@[\w:-]+"#) // swiftlint:disable:this force_try

    /// The tags the live peers answer to, with `@all`.
    static func knownTags(_ directory: AssistantDirectory) -> Set<String> {
        var tags: Set<String> = ["@all"]
        for peer in directory.peers {
            if let handle = directory.handle(of: peer.sessionID) { tags.insert("@\(handle)") }
            if let handle = directory.workspaceHandle(of: peer.workspaceID) { tags.insert("@ws:\(handle)") }
        }
        return tags
    }

    /// The words that name a session, a workspace or `@all`; any other `@word` stays plain text.
    static func tagRanges(_ string: String, known: Set<String>) -> [NSRange] {
        let text = string as NSString
        return pattern.matches(in: string, range: NSRange(location: 0, length: text.length)).map(\.range)
            .filter { known.contains(text.substring(with: $0).lowercased()) }
    }

    static func paragraph(lineHeight: CGFloat) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        return style
    }

    /// A fixed line height puts its spare room above the glyphs; the baseline offset centres them.
    static func attributes(lineHeight: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph(lineHeight: lineHeight),
         .baselineOffset: floor((lineHeight - ceil(font.ascender - font.descender)) / 2)]
    }

    /// Kerning on the character before a tag and on its own last one makes room for the chip's padding.
    static func apply(to storage: NSTextStorage, known: Set<String>, lineHeight: CGFloat) {
        let text = storage.string as NSString
        storage.beginEditing()
        storage.setAttributes(attributes(lineHeight: lineHeight), range: NSRange(location: 0, length: text.length))
        for tag in tagRanges(storage.string, known: known) {
            storage.addAttribute(.font, value: tagFont, range: tag)
            storage.addAttribute(.kern, value: chipPad, range: NSRange(location: NSMaxRange(tag) - 1, length: 1))
            if tag.location > 0, text.character(at: tag.location - 1) != 0x0A {
                storage.addAttribute(.kern, value: chipPad, range: NSRange(location: tag.location - 1, length: 1))
            } else {
                let style = paragraph(lineHeight: lineHeight)
                style.firstLineHeadIndent = chipPad
                storage.addAttribute(.paragraphStyle, value: style, range: text.paragraphRange(for: tag))
            }
        }
        storage.endEditing()
    }

    /// Fills each tag's rounded chip, one per line it spans; the last character's kern is its right padding.
    static func drawChips(_ tags: [NSRange], layoutManager: NSLayoutManager, textContainer: NSTextContainer,
                          origin: NSPoint, lineHeight: CGFloat) {
        NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
        for tag in tags {
            let glyphs = layoutManager.glyphRange(forCharacterRange: tag, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                                  in: textContainer) { rect, _ in
                let chip = NSRect(x: rect.minX - chipPad + origin.x, y: rect.minY + origin.y + (lineHeight - 19) / 2,
                                  width: rect.width + chipPad, height: 19)
                NSBezierPath(roundedRect: chip, xRadius: 5, yRadius: 5).fill()
            }
        }
    }
}
