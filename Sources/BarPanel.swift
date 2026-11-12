import AppKit

enum PanelStyle: String, CaseIterable {
    case shelf, tray, index

    var title: String { rawValue.capitalized }
}

struct TraySlot: Equatable {
    let row: Int, column: Int, span: Int
}

/// A temporary panel of native buttons; captures stay at their original point size.
final class BarPanel: NSPanel {
    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private var windows: [StatusWindow] = []
    private var buttons: [NSButton] = []
    private var monitors: [Any] = []
    private var style: PanelStyle = .shelf
    /// Tray grid positions of `buttons`, in the same order (Settings has none).
    private var traySlots: [TraySlot] = []
    var onItemClick: ((StatusWindow) -> Void)?
    var onSettings: (() -> Void)?
    var onDismiss: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .transient]
        hidesOnDeactivate = false
        hasShadow = true
        setAccessibilityLabel("Hidden menu bar icons")

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        contentView = effect

        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.autoresizingMask = [.width, .height]
        effect.addSubview(scroll)
        stack.spacing = 6
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        scroll.documentView = stack
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { dismiss() }

    func show(windows: [StatusWindow], images: [CGWindowID: NSImage], anchor: NSRect,
              on screen: NSScreen, appearance: NSAppearance, style: PanelStyle = .shelf) {
        removeMonitors()
        self.windows = windows
        self.style = style
        self.appearance = appearance
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttons.removeAll()
        stack.orientation = style == .shelf ? .horizontal : .vertical
        stack.alignment = style == .shelf ? .centerY : .leading
        stack.spacing = style == .shelf ? 0 : 6

        // Each app pads its menu-bar item differently, so Shelf gaps are only even between trimmed glyphs.
        let images = style == .shelf ? images.mapValues(Self.trimmingSides) : images
        let tiles = windows.map { images[$0.id]?.size ?? NSSize(width: 22, height: 22) }
        let grid = style == .tray ? Self.trayGrid(widths: tiles.map(\.width)) : nil
        // Buttons follow the tray's reading order, so Tab and the arrow keys match the screen.
        let order = grid.map { g in windows.indices.sorted { (g.slots[$0].row, g.slots[$0].column) < (g.slots[$1].row, g.slots[$1].column) } }
            ?? Array(windows.indices)
        traySlots = grid.map { g in order.map { g.slots[$0] } } ?? []
        var row: NSStackView?
        for i in order {
            let item = windows[i]
            let name = item.label ?? item.appName
            let button = NSButton(title: "", target: self, action: #selector(itemClicked(_:)))
            button.tag = i
            button.isBordered = false
            button.imageScaling = .scaleNone
            button.toolTip = name
            button.setAccessibilityLabel(name)
            button.setAccessibilityHelp("Open \(name) menu")
            button.image = images[item.id] ?? NSRunningApplication(processIdentifier: item.pid)?.icon
            let tile = tiles[i]
            if images[item.id] == nil {
                button.image = button.image?.copy() as? NSImage
                button.image?.size = tile
            }
            if style == .index {
                button.title = name
                button.imagePosition = .imageLeading
                button.alignment = .left
                button.font = .menuFont(ofSize: 13)
                button.lineBreakMode = .byTruncatingTail
                button.widthAnchor.constraint(equalToConstant: max(200, tile.width + 140)).isActive = true
            } else {
                button.imagePosition = .imageOnly
                if button.image == nil { button.title = String(name.prefix(1)) }
                let width = grid.map { max(Self.trayCellWidth(span: $0.slots[i].span, cell: $0.cell), tile.width) }
                    ?? max(24, tile.width + Self.shelfGap)
                button.widthAnchor.constraint(equalToConstant: width).isActive = true
            }
            button.heightAnchor.constraint(equalToConstant: max(style == .shelf ? 24 : 28, tile.height)).isActive = true
            buttons.append(button)
            if let grid {
                if grid.slots[i].row == stack.arrangedSubviews.count {
                    let next = NSStackView()
                    next.orientation = .horizontal
                    next.alignment = .centerY
                    next.spacing = Self.traySpacing
                    stack.addArrangedSubview(next)
                    row = next
                }
                row?.addArrangedSubview(button)
            } else {
                stack.addArrangedSubview(button)
            }
        }

        let settings = NSButton(title: style == .shelf ? "" : "Settings…", target: self, action: #selector(settingsClicked))
        settings.isBordered = false
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        settings.imagePosition = style == .shelf ? .imageOnly : .imageLeading
        settings.font = .menuFont(ofSize: 12)
        settings.contentTintColor = .secondaryLabelColor
        settings.toolTip = "Settings"
        settings.setAccessibilityLabel("Settings")
        settings.heightAnchor.constraint(equalToConstant: 24).isActive = true
        if style == .shelf { settings.widthAnchor.constraint(equalToConstant: 24).isActive = true }
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(10, after: last) }
        stack.addArrangedSubview(settings)
        buttons.append(settings)
        for (index, button) in buttons.enumerated() {
            button.nextKeyView = buttons[(index + 1) % buttons.count]
        }

        let size = stack.fittingSize
        stack.setFrameSize(size)
        let frame = Self.frame(for: size, anchor: anchor, visibleFrame: screen.visibleFrame)
        setFrame(frame, display: true)
        scroll.frame = contentView!.bounds
        scroll.hasHorizontalScroller = size.width > frame.width
        scroll.hasVerticalScroller = size.height > frame.height
        scroll.contentView.scroll(to: NSPoint(x: 0, y: stack.isFlipped ? 0 : max(0, size.height - frame.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
        if !isVisible {
            makeKeyAndOrderFront(nil)
            makeFirstResponder(nil)
        }

        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            self?.dismiss()
        }) {
            monitors.append(monitor)
        }
    }

    static func frame(for size: NSSize, anchor: NSRect, visibleFrame: NSRect) -> NSRect {
        let top = min(anchor.minY - 6, visibleFrame.maxY)
        let width = min(size.width, max(1, visibleFrame.width - 16))
        let height = min(size.height, max(1, top - visibleFrame.minY - 8))
        return NSRect(x: max(visibleFrame.minX + 8, min(anchor.maxX, visibleFrame.maxX - 8) - width),
                      y: top - height, width: width, height: height)
    }

    static let shelfGap: CGFloat = 14

    /// Drops the transparent columns either side of a glyph. The height stays, so glyphs keep their
    /// place on the bar's baseline. A blank image comes back unchanged.
    static func trimmingSides(_ image: NSImage) -> NSImage {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let w = cg.width, h = cg.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data
        else { return image }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        // 10 percent ignores leftover backdrop noise; Tailscale's faint dots measure about 26 percent.
        let inked = (0..<w).filter { x in (0..<h).contains { y in px[(y * w + x) * 4 + 3] >= 26 } }
        guard let first = inked.first, let last = inked.last else { return image }
        // One pixel either side keeps anti-aliased edges below the threshold.
        let from = max(0, first - 1), width = min(w - 1, last + 1) - from + 1
        guard let piece = cg.cropping(to: CGRect(x: from, y: 0, width: width, height: h)) else { return image }
        return NSImage(cgImage: piece, size: NSSize(width: CGFloat(width) * image.size.width / CGFloat(w), height: image.size.height))
    }

    static let trayCell: CGFloat = 36
    static let traySpacing: CGFloat = 8

    static func trayCellWidth(span: Int, cell: CGFloat) -> CGFloat {
        CGFloat(span) * cell + CGFloat(span - 1) * traySpacing
    }

    /// Tray layout: every item spans whole cells, so full rows are equally wide and a wide item
    /// (Vitals) no longer leaves the other rows short. Rows are at least 3 cells, or as wide as the
    /// widest item. An item that doesn't fit starts a new row; later items backfill the gap it left.
    static func trayGrid(widths: [CGFloat]) -> (cell: CGFloat, slots: [TraySlot]) {
        let pitch = trayCell + traySpacing
        // Up to one spacing of overhang still counts as one cell, so a 38 pt icon doesn't take two.
        let spans = widths.map { 1 + Int((max(0, $0 - pitch) / pitch).rounded(.up)) }
        // Then widen the cell (36 to 44 pt) until every item fits its span, so full rows match to the point.
        let cell = zip(widths, spans).reduce(trayCell) { max($0, ($1.0 - CGFloat($1.1 - 1) * traySpacing) / CGFloat($1.1)) }
        let columns = max(3, spans.max() ?? 0)
        var used: [Int] = []
        let slots = spans.map { span in
            let row = used.firstIndex { $0 + span <= columns } ?? used.count
            if row == used.count { used.append(0) }
            defer { used[row] += span }
            return TraySlot(row: row, column: used[row], span: span)
        }
        return (cell.rounded(.up), slots)
    }

    /// Up/down in the tray: the item in the next row that covers this one's first column, or that
    /// row's last item when it is shorter; nil past the top or bottom row.
    static func trayNeighbor(of index: Int, in slots: [TraySlot], down: Bool) -> Int? {
        let here = slots[index]
        let next = slots.indices.filter { slots[$0].row == here.row + (down ? 1 : -1) }
        return next.first { slots[$0].column <= here.column && here.column < slots[$0].column + slots[$0].span } ?? next.last
    }

    override func keyDown(with event: NSEvent) {
        guard !buttons.isEmpty else { return super.keyDown(with: event) }
        let current = buttons.firstIndex { $0 === firstResponder }
        let step: Int
        switch event.keyCode {
        case 123: step = -1
        case 124: step = 1
        case 125, 126:
            let down = event.keyCode == 125
            guard style == .tray, let here = current else {
                step = down ? 1 : -1
                break
            }
            if here < traySlots.count {
                // Below the last row is Settings; above the first row, stay.
                focus(Self.trayNeighbor(of: here, in: traySlots, down: down) ?? (down ? buttons.count - 1 : here))
            } else if !down && !traySlots.isEmpty {
                focus(traySlots.count - 1)
            }
            return
        case 36, 76:
            if let current { buttons[current].performClick(nil) }
            else { focus(0) }
            return
        default:
            super.keyDown(with: event)
            return
        }
        focus(current.map { max(0, min(buttons.count - 1, $0 + step)) } ?? 0)
    }

    private func focus(_ index: Int) {
        let button = buttons[index]
        makeFirstResponder(button)
        button.scrollToVisible(button.bounds)
    }

    @objc private func itemClicked(_ sender: NSButton) {
        let item = windows[sender.tag]
        dismiss()
        onItemClick?(item)
    }

    @objc private func settingsClicked() {
        dismiss()
        onSettings?()
    }

    func dismiss() {
        removeMonitors()
        orderOut(nil)
        onDismiss?()
    }

    deinit { removeMonitors() }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }
}
