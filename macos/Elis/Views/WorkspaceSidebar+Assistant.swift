import ElisCore
import AppKit

/// The pinned Elis row: the outline's first root in every mode, selected exactly while the chat shows.
extension WorkspaceSidebar.Coordinator {
    // the row never joins a multi-selection: a click on it takes it alone, a click elsewhere drops it
    func outlineView(_ outlineView: NSOutlineView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        let row = outlineView.row(forItem: assistantNode)
        guard row >= 0, proposed.contains(row), proposed.count > 1 else { return proposed }
        return outlineView.clickedRow == row ? IndexSet(integer: row) : proposed.subtracting(IndexSet(integer: row))
    }

    /// showsAssistantForSelection shows the chat when the user selected the row; the caller stops there.
    func showsAssistantForSelection(in outline: NSOutlineView) -> Bool {
        let row = outline.row(forItem: assistantNode)
        guard row >= 0, outline.selectedRowIndexes == IndexSet(integer: row) else { return false }
        if !store.assistantShown { actions.showAssistant(in: store) }
        return true
    }

    /// selectAssistantRow selects the row while the chat shows; false leaves the nil selection to the caller.
    func selectAssistantRow(in outline: NSOutlineView) -> Bool {
        let row = outline.row(forItem: assistantNode)
        guard store.assistantShown, row >= 0 else { return false }
        if outline.selectedRowIndexes != IndexSet(integer: row) { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        return true
    }

    /// refreshAssistantRow re-applies the live cell's badge and theme color; reconcile runs it on every change.
    func refreshAssistantRow() {
        guard let outline = outlineView, case let row = outline.row(forItem: assistantNode), row >= 0,
              let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarAssistantCellView else { return }
        configure(cell)
    }

    private func configure(_ cell: SidebarAssistantCellView) {
        cell.textField?.font = .systemFont(ofSize: GhosttyApp.shared.sidebarFontSize, weight: .semibold)
        cell.textField?.textColor = SidebarCellView.themeTextColor(selected: false)
        cell.badge.count = effectiveUnseen(actions.assistant.unread)
    }

    /// refusesAssistantDrop is true for a drop on the row or in the root gap above it.
    func refusesAssistantDrop(item: Any?, childIndex: Int) -> Bool {
        (item as? SidebarNode)?.kind == .assistant || (item == nil && childIndex == 0)
    }

    func assistantCell(in outlineView: NSOutlineView) -> SidebarAssistantCellView {
        let identifier = NSUserInterfaceItemIdentifier("assistant-cell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarAssistantCellView ?? SidebarAssistantCellView()
        cell.identifier = identifier
        configure(cell)
        return cell
    }

    func assistantRowView(in outlineView: NSOutlineView) -> SidebarAssistantRowView {
        let identifier = NSUserInterfaceItemIdentifier("sidebar-assistant-row")
        if let reused = outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarAssistantRowView { return reused }
        let view = SidebarAssistantRowView()
        view.identifier = identifier
        return view
    }
}

/// SidebarAssistantCellView is the Elis row: the app icon, "Elis" and the unread badge, 8pt inside the pill.
final class SidebarAssistantCellView: NSTableCellView {
    let badge = BadgeView()

    private static let dog = NSImage.elisDog(side: 18, radius: 4)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let icon = NSImageView(image: Self.dog)
        let name = NSTextField(labelWithString: "Elis")
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [icon, name, badge] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        imageView = icon
        textField = name
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Elis")
        setAccessibilityIdentifier("assistant-row")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    // VoiceOver's press takes the click's path: selecting the row shows the chat
    override func accessibilityPerformPress() -> Bool {
        guard let outline = superview?.superview as? NSOutlineView, case let row = outline.row(for: self), row >= 0 else { return false }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return true
    }
}

/// SidebarAssistantRowView draws the Elis card and a session pill in the accent color; no band, tint, wash or wave.
final class SidebarAssistantRowView: SidebarRowView {
    override var selectionColor: NSColor { NSColor(named: "AccentColor") ?? .controlAccentColor }

    override var selectionRect: NSRect {
        let rect = super.selectionRect
        guard let minX = (superview as? SidebarOutlineView)?.assistantPillMinX else { return rect }
        return NSRect(x: minX, y: rect.minY, width: rect.maxX - minX, height: rect.height)
    }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    override func drawBackground(in dirtyRect: NSRect) {
        let card = bandRect(.single), cardRadius = Self.bandRadius
        (isDark ? NSColor.white.withAlphaComponent(0.045) : NSColor.black.withAlphaComponent(0.035)).setFill()
        NSBezierPath(roundedRect: card, xRadius: cardRadius, yRadius: cardRadius).fill()
        let border = NSBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5), xRadius: cardRadius - 0.5, yRadius: cardRadius - 0.5)
        border.lineWidth = 1
        NSColor.separatorColor.setStroke()
        border.stroke()
        let rect = rowRect, radius = Self.rowRadius
        if isSelected {
            drawSelectionPill(in: rect)
        } else if isHovered {
            (GhosttyApp.shared.terminalForegroundColor ?? .labelColor).withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        }
    }
}
