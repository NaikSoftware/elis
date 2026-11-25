import AppKit
import ElisCore
import SwiftUI

extension NSImage {
    /// The app icon without the icon grid's transparent margin, clipped to `radius`, as the Elis row and chat draw it.
    @MainActor static func elisDog(side: CGFloat, radius: CGFloat) -> NSImage {
        let icon = NSApp.applicationIconImage
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            guard let icon else { return false }
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
            let bleed = rect.width * 100 / 824
            icon.draw(in: rect.insetBy(dx: -bleed, dy: -bleed))
            return true
        }
    }
}

/// AssistantView is the Elis chat in the detail area: the transcript column and the composer under it.
struct AssistantView: View {
    let model: AssistantModel
    let store: AppStore
    /// The window backing behind the chat: the terminal background, as the title bar shows it.
    let background: Color
    let dark: Bool
    @State private var composer = AssistantComposerState()
    @State private var columnWidth: CGFloat = 680
    private static let column: CGFloat = 680

    var body: some View {
        VStack(spacing: 0) {
            if model.entries.isEmpty && !model.running {
                emptyState
            } else {
                transcript
            }
            AssistantComposerBox(model: model, store: store, state: composer, dark: dark)
                .frame(maxWidth: Self.column)
                .padding(EdgeInsets(top: 12, leading: 32, bottom: 18, trailing: 32))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(background)
        .contentShape(Rectangle())
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(nsImage: .elisDog(side: 64, radius: 14))
            Text(verbatim: "Elis")
                .font(.system(size: 20, weight: .semibold))
                .padding(.top, 4)
            Text("Ask about your sessions. Tag one with @, or drag a sidebar row onto the message box.")
                .font(.system(size: 13))
                .lineSpacing(13 * 0.45 - 3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(EdgeInsets(top: 28, leading: 32, bottom: 4, trailing: 32))
    }

    private var transcript: some View {
        let directory = AssistantDirectory(model.peers())
        return GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(model.entries, id: \.id) { entry in
                        AssistantEntryView(entry: entry, directory: directory, columnWidth: columnWidth, dark: dark,
                                           known: knownTags(directory),
                                           goTo: goTo)
                    }
                    if model.running {
                        Text("Elis is working…")
                            .font(.system(size: 13).italic())
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("assistant-working")
                    }
                }
                .frame(maxWidth: Self.column, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { columnWidth = $0 }
                .frame(maxWidth: .infinity)
                .padding(EdgeInsets(top: 28, leading: 32, bottom: 4, trailing: 32))
                // a short transcript starts at the top; the bottom anchor only follows a long one's end
                .frame(minHeight: viewport.size.height, alignment: .top)
            }
            .defaultScrollAnchor(.bottom)
        }
    }

    private func knownTags(_ directory: AssistantDirectory) -> Set<String> {
        var tags: Set<String> = ["@all"]
        for peer in directory.peers {
            if let handle = directory.handle(of: peer.sessionID) { tags.insert("@\(handle)") }
            if let handle = directory.workspaceHandle(of: peer.workspaceID) { tags.insert("@ws:\(handle)") }
        }
        return tags
    }

    private func goTo(_ sessionID: String) {
        Task { _ = await model.perform(ControlRequest(cmd: .sessionGo, target: sessionID)) }
    }
}

/// One transcript entry: a user bubble, an answer, a sent or reply card, or an error line.
private struct AssistantEntryView: View {
    let entry: AssistantEntry
    let directory: AssistantDirectory
    let columnWidth: CGFloat
    let dark: Bool
    let known: Set<String>
    let goTo: (String) -> Void

    var body: some View {
        switch entry.kind {
        case .user:
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                AssistantTaggedText(text: entry.text, known: known, maxWidth: columnWidth * 0.76 - 26)
                    .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .background(Color.appAccent.opacity(dark ? 0.20 : 0.14), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.appAccent.opacity(dark ? 0.65 : 0.55)))
            }
        case .assistant:
            AssistantMarkdown(text: entry.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("assistant-answer")
        case .sent, .reply:
            card
        case .error:
            Text(verbatim: entry.text)
                .font(.system(size: 13))
                .foregroundStyle(Color(nsColor: dark ? NSColor(srgbRed: 1, green: 0x69 / 255, blue: 0x61 / 255, alpha: 1)
                                                     : NSColor(srgbRed: 0xD7 / 255, green: 0, blue: 0x15 / 255, alpha: 1)))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("assistant-error")
        }
    }

    private var sent: Bool { entry.kind == .sent }

    private var card: some View {
        let peers = sent ? entry.to ?? [] : entry.from.map { [$0] } ?? []
        return HStack(spacing: 0) {
            if sent { Spacer(minLength: 0) }
            VStack(alignment: .leading, spacing: 7) {
                Grid(horizontalSpacing: 7, verticalSpacing: 6) {
                    ForEach(Array(peers.enumerated()), id: \.offset) { index, id in
                        GridRow {
                            Text(index == 0 ? (sent ? "To" : "From") : "")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .frame(minWidth: 28, alignment: .leading)
                            AssistantChip(tag: "@" + (directory.handle(of: id) ?? id))
                            Text(verbatim: directory.peers.first { $0.sessionID == id }?.name ?? "")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            AssistantGoButton { goTo(id) }
                        }
                    }
                }
                Text(verbatim: entry.text)
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .foregroundStyle(sent ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(EdgeInsets(top: 10, leading: 12, bottom: 11, trailing: 12))
            .background(sent ? Color.clear : Color.primary.opacity(dark ? 0.045 : 0.035), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.10)))
            .fitWidth(min: min(360, columnWidth), max: columnWidth * 0.8)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(sent ? "assistant-sent" : "assistant-reply")
            if !sent { Spacer(minLength: 0) }
        }
    }
}

/// FitWidth sizes a card to its content's one-line width, kept between `min` and `max`, wrapping past `max`.
private extension View {
    func fitWidth(min: CGFloat, max: CGFloat) -> some View { FitWidth(min: min, max: max) { self } }
}

private struct FitWidth: Layout {
    let min: CGFloat
    let max: CGFloat

    private func width(_ subview: LayoutSubview, proposal: ProposedViewSize) -> CGFloat {
        Swift.min(Swift.max(subview.sizeThatFits(.unspecified).width, min), max, proposal.width ?? .infinity)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let width = width(subview, proposal: proposal)
        return CGSize(width: width, height: subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// A tag chip: the AskChoiceList current-row highlight, accent 25% under a 5pt radius.
struct AssistantChip: View {
    let tag: String

    var body: some View {
        Text(verbatim: tag)
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .frame(height: 19)
            .background(Color.appAccent.opacity(0.25), in: RoundedRectangle(cornerRadius: 5))
    }
}

/// The card's borderless "go to session" arrow; the selection it makes hides the chat.
private struct AssistantGoButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.appAccent)
                .frame(width: 18, height: 18)
                .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
        .help("Go to Session")
        .accessibilityLabel("Go to Session")
        .accessibilityIdentifier("assistant-go")
    }
}

/// A user message with its tags drawn as chips, in the composer's own text system.
private struct AssistantTaggedText: NSViewRepresentable {
    let text: String
    let known: Set<String>
    let maxWidth: CGFloat

    func makeNSView(context _: Context) -> AssistantTagLabel { AssistantTagLabel() }

    func updateNSView(_ view: AssistantTagLabel, context _: Context) {
        view.show(text, known: known)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: AssistantTagLabel, context _: Context) -> CGSize? {
        view.size(fitting: min(proposal.width ?? maxWidth, maxWidth))
    }
}

/// AssistantTagLabel is a read-only text view: no selection or focus, so a click leaves the keys with the composer.
final class AssistantTagLabel: NSTextView {
    private var known: Set<String> = []
    override var acceptsFirstResponder: Bool { false }

    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = false
        drawsBackground = false
        textContainerInset = .zero
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ text: String, known: Set<String>) {
        guard let storage = textStorage, storage.string != text || self.known != known else { return }
        self.known = known
        storage.setAttributedString(NSAttributedString(string: text))
        AssistantTagStyle.apply(to: storage, known: known, lineHeight: 20)
        needsDisplay = true
    }

    func size(fitting width: CGFloat) -> CGSize {
        guard let layoutManager, let textContainer else { return .zero }
        textContainer.size = NSSize(width: max(1, width), height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        return CGSize(width: ceil(used.width), height: ceil(used.height))
    }

    override func layout() {
        super.layout()
        textContainer?.size = NSSize(width: bounds.width, height: .greatestFiniteMagnitude)
    }

    override func draw(_ dirtyRect: NSRect) {
        if let layoutManager, let textContainer {
            AssistantTagStyle.drawChips(AssistantTagStyle.tagRanges(string, known: known), layoutManager: layoutManager,
                                        textContainer: textContainer, origin: textContainerOrigin, lineHeight: 20)
        }
        super.draw(dirtyRect)
    }
}

/// The provider pop-up, Clear and Send under the composer's text, in the field's rounded chrome.
private struct AssistantComposerBox: View {
    let model: AssistantModel
    let store: AppStore
    let state: AssistantComposerState
    let dark: Bool
    @State private var menuAnchor = AssistantMenuAnchor()
    @State private var menuOpen = false
    @State private var clearHovering = false

    private var empty: Bool { state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var field: Color { dark ? Color(red: 0x2F / 255, green: 0x31 / 255, blue: 0x37 / 255) : .white }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AssistantComposer(model: model, store: store, state: state)
                .frame(height: CGFloat(state.lines) * AssistantComposerTextView.lineHeight)
            HStack(spacing: 4) {
                providerButton
                Spacer(minLength: 0)
                clearButton
                sendButton
            }
        }
        .padding(EdgeInsets(top: 9, leading: 12, bottom: 8, trailing: 10))
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(field)
                .overlay { if state.dropping { RoundedRectangle(cornerRadius: 12).fill(Color.appAccent.opacity(dark ? 0.20 : 0.14)) } }
                .shadow(color: .black.opacity(dark ? 0.25 : 0.05), radius: 1, y: 1)
                .shadow(color: .black.opacity(dark ? 0.25 : 0.06), radius: dark ? 9 : 7, y: dark ? 6 : 4)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(state.dropping ? Color.appAccent : Color.primary.opacity(0.14))
        }
        .overlay {
            if state.dropping {
                RoundedRectangle(cornerRadius: 13.5).stroke(Color.appAccent.opacity(0.30), lineWidth: 3).padding(-1.5)
            }
        }
        .background(AssistantDropZone(state: state, ring: state.focused && !state.dropping).padding(-AssistantDropZone.ringRoom))
        .overlay(alignment: .topLeading) { completionPanel }
        .onAppear(perform: detectProviders)
    }

    // MARK: - Provider

    private var detecting: Bool { SessionLaunchers.path == nil && model.providers.isEmpty }

    private var current: SessionLauncher? {
        model.provider.flatMap { model.providers.contains($0) ? $0 : nil } ?? model.providers.first
    }

    private var providerButton: some View {
        Button(action: openProviders) {
            HStack(spacing: 6) {
                if let current, let image = current.image(pointSize: 13) {
                    Image(nsImage: image).resizable().frame(width: 13, height: 13).opacity(dark ? 0.75 : 0.62)
                }
                Text(verbatim: detecting ? "Detecting agents…" : current?.title ?? "No agent found")
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .padding(EdgeInsets(top: 0, leading: 7, bottom: 0, trailing: 5))
            .frame(height: 24)
            .background(Color.primary.opacity(menuOpen ? (dark ? 0.14 : 0.11) : (dark ? 0.08 : 0.065)), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .background(menuAnchor)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(detecting)
        .accessibilityLabel("Provider")
        .accessibilityValue(current?.title ?? "")
        .accessibilityIdentifier("assistant-provider")
    }

    /// The composer's picker is what starts agent detection; the tree only ever reads the cached list.
    private func detectProviders() {
        _ = SessionLaunchers.available
        Task { @MainActor in
            await SessionLaunchers.settled()
            model.refresh()
        }
    }

    private func openProviders() {
        detectProviders()
        guard let view = menuAnchor.view else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: "Found on this system"))
        let target = AssistantMenuTarget { provider in
            var args = ControlArgs()
            args.provider = provider.rawValue
            Task { @MainActor in
                _ = await model.perform(ControlRequest(cmd: .assistantProvider, args: args))
                model.refresh()
            }
        }
        for provider in model.providers {
            let item = NSMenuItem(title: provider.title, action: #selector(AssistantMenuTarget.pick(_:)), keyEquivalent: "")
            item.target = target
            item.image = provider.image(pointSize: 15)
            item.state = provider == current ? .on : .off
            item.representedObject = provider.rawValue
            menu.addItem(item)
        }
        if !model.providers.isEmpty {
            menu.addItem(.separator())
            let footer = NSMenuItem(title: "Applies from the next message", action: nil, keyEquivalent: "")
            footer.attributedTitle = NSAttributedString(string: footer.title, attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor])
            footer.isEnabled = false
            menu.addItem(footer)
        }
        menuOpen = true
        // the menu sits on the button's top edge, its items' text in line with the button's
        menu.popUp(positioning: nil, at: NSPoint(x: -8, y: view.bounds.height + 2 + menu.size.height), in: view)
        withExtendedLifetime(target) { menuOpen = false }
    }

    // MARK: - Clear and Send

    private var clearDisabled: Bool { model.entries.isEmpty && !model.running }

    private var clearButton: some View {
        Button(action: confirmClear) {
            Image(systemName: "trash")
                .font(.system(size: 15))
                .foregroundStyle(clearHovering && !clearDisabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 28, height: 28)
                .background(clearHovering && !clearDisabled ? Color.primary.opacity(dark ? 0.08 : 0.065) : .clear,
                            in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(clearDisabled)
        .opacity(clearDisabled ? 0.35 : 1)
        .onHover { clearHovering = $0 }
        .help("Clear Chat")
        .accessibilityLabel("Clear Chat")
        .accessibilityIdentifier("assistant-clear")
    }

    private func confirmClear() {
        guard let window = state.textView?.window else { return }
        let alert = NSAlert()
        alert.messageText = "Clear the Elis chat?"
        alert.informativeText = "Elis also forgets the conversation."
        alert.addButton(withTitle: "Cancel")
        let clear = alert.addButton(withTitle: "Clear")
        clear.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            guard response == .alertSecondButtonReturn else { return }
            Task { @MainActor in _ = await model.perform(ControlRequest(cmd: .assistantClear)) }
        }
    }

    private var sendButton: some View {
        Button { state.textView?.send() } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(empty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.white))
                .frame(width: 28, height: 28)
                .background(empty ? Color.primary.opacity(dark ? 0.14 : 0.11) : Color.appAccent, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(empty)
        .help("Send")
        .accessibilityLabel("Send")
        .accessibilityIdentifier("assistant-send")
    }

    // MARK: - Completion

    @ViewBuilder private var completionPanel: some View {
        if !state.completion.isEmpty {
            GeometryReader { box in
                let x = min(max(0, 12 + state.completionX), max(0, box.size.width - 300))
                ScrollViewReader { scroller in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(state.completion.enumerated()), id: \.element.id) { index, row in
                                completionRow(row, highlighted: index == state.highlighted)
                                    .id(row.id)
                                    .onTapGesture { state.textView?.acceptCompletion(index) }
                            }
                        }
                        .padding(4)
                    }
                    .scrollIndicators(.automatic)
                    .frame(width: 300, height: min(CGFloat(state.completion.count), 8) * 28 + 8)
                    .onChange(of: state.highlighted) { _, index in
                        if state.completion.indices.contains(index) { scroller.scrollTo(state.completion[index].id) }
                    }
                }
                .background(dark ? Color(red: 0x2D / 255, green: 0x2E / 255, blue: 0x33 / 255) : .white, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(dark ? 0.13 : 0.12)))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.22), radius: 17, y: 12)
                .offset(x: x, y: -(min(CGFloat(state.completion.count), 8) * 28 + 8) - 6)
            }
            .accessibilityIdentifier("assistant-completion")
        }
    }

    private func completionRow(_ row: AssistantCompletionRow, highlighted: Bool) -> some View {
        HStack(spacing: 10) {
            completionIcon(row.icon).frame(width: 16, height: 16)
            Text(verbatim: row.tag).font(.system(size: 13, weight: .medium)).lineLimit(1).frame(width: 96, alignment: .leading)
            Text(verbatim: row.name).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(highlighted ? Color.primary.opacity(dark ? 0.14 : 0.11) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("assistant-completion-\(row.tag)")
    }

    @ViewBuilder private func completionIcon(_ icon: AssistantCompletionRow.Icon) -> some View {
        switch icon {
        case .all:
            Image(systemName: "square.grid.2x2").font(.system(size: 13)).foregroundStyle(.secondary)
        case .workspace:
            Image("workspace-stack").resizable().scaledToFit().foregroundStyle(.secondary)
        case .session(let agent):
            if let image = (agent ?? .terminal).image(pointSize: 15) {
                Image(nsImage: image).resizable().scaledToFit().opacity(dark ? 0.75 : 0.62)
            }
        }
    }
}

/// The view the provider menu pops up from.
private struct AssistantMenuAnchor: NSViewRepresentable {
    final class Box { weak var view: NSView? }
    let box = Box()
    var view: NSView? { box.view }

    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ view: NSView, context _: Context) { box.view = view }
}

/// The provider menu's item target; the menu holds it no longer than the pop-up's run loop.
private final class AssistantMenuTarget: NSObject {
    let onPick: (SessionLauncher) -> Void

    init(onPick: @escaping (SessionLauncher) -> Void) { self.onPick = onPick }

    @MainActor @objc func pick(_ sender: NSMenuItem) {
        (sender.representedObject as? String).flatMap(SessionLauncher.init(rawValue:)).map(onPick)
    }
}

/// AssistantDropZone makes the whole field a drop target for sidebar rows, not only its text, and draws the
/// standard focus ring around the field while the composer has focus in a key window.
private struct AssistantDropZone: NSViewRepresentable {
    /// The room the zone extends past the field on each side, so the ring is not clipped.
    static let ringRoom: CGFloat = 4
    let state: AssistantComposerState
    let ring: Bool

    func makeNSView(context _: Context) -> DropView { DropView(state: state) }

    func updateNSView(_ view: DropView, context _: Context) {
        view.ring = ring
    }

    final class DropView: NSView {
        let state: AssistantComposerState
        var ring = false {
            didSet { if ring != oldValue { needsDisplay = true } }
        }

        @objc private func keyChanged(_ note: Notification) {
            if note.object as? NSWindow === window { needsDisplay = true }
        }

        override func draw(_: NSRect) {
            guard ring, window?.isKeyWindow == true else { return }
            NSGraphicsContext.saveGraphicsState()
            NSFocusRingPlacement.only.set()
            NSBezierPath(roundedRect: bounds.insetBy(dx: AssistantDropZone.ringRoom, dy: AssistantDropZone.ringRoom), xRadius: 12, yRadius: 12).fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        init(state: AssistantComposerState) {
            self.state = state
            super.init(frame: .zero)
            registerForDraggedTypes([sessionPasteboardType, workspacePasteboardType])
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(keyChanged), name: name, object: nil)
            }
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
            state.textView?.sidebarDrag(sender) ?? []
        }

        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
            state.textView?.sidebarDrag(sender) ?? []
        }

        override func draggingExited(_: (any NSDraggingInfo)?) { state.dropping = false }

        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            state.textView?.dropSidebarRow(sender, at: nil) ?? false
        }
    }
}
