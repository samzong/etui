import AppKit
import ImageIO

private final class ClipContent: NSView {
    static let style = PanelStyle(width: 440, pad: 6, header: 32, rowHeight: 30, rows: 9,
                                  highlightInset: 2, cornerRadius: 7, highlightOpacity: 0.85,
                                  iconRect: NSRect(x: 12, y: 4, width: 22, height: 22),
                                  labelRect: NSRect(x: 12, y: 6, width: 372, height: 18),
                                  fontSize: 13, badgeRect: NSRect(x: 388, y: 6, width: 32, height: 18),
                                  tintsSelection: true)

    private let field = NSTextField(labelWithString: "")
    private let rows = (0 ..< ClipContent.style.rows).map { _ in Row(style: ClipContent.style) }
    private var shown = 0

    static func height(rows: Int, header: Bool) -> CGFloat {
        style.height(header: header ? style.header : 0, rows: rows)
    }

    convenience init() {
        self.init(frame: NSRect(x: 0, y: 0, width: Self.style.width, height: Self.height(rows: 0, header: false)))
        wantsLayer = true
        addSubview(GlassPanel(frame: bounds))
        field.font = .systemFont(ofSize: 15)
        field.lineBreakMode = .byTruncatingHead
        field.usesSingleLineMode = true
        field.autoresizingMask = [.width, .minYMargin]
        field.isHidden = true
        addSubview(field)
        rows.forEach { addSubview($0.root) }
        place(height: frame.height)
    }

    func render(_ clips: [Clip], query: String, selected: Int, image: (Clip) -> URL?) -> CGFloat {
        shown = min(clips.count, rows.count)
        field.stringValue = query
        field.isHidden = query.isEmpty
        for (index, row) in rows.enumerated() {
            row.root.isHidden = index >= shown
            guard index < shown else { continue }
            let picture = image(clips[index]).flatMap(Self.thumbnail)
            row.icon.isHidden = picture == nil
            if let picture {
                row.icon.frame = NSRect(x: 12, y: 4, width: picture.size.width, height: picture.size.height)
            }
            row.label.isHidden = picture != nil
            row.show(title: clips[index].preview, image: picture, badge: "⌘\(index + 1)", selected: index == selected)
        }
        return Self.height(rows: shown, header: !query.isEmpty)
    }

    func index(at point: NSPoint) -> Int? {
        Self.style.index(at: point, panelHeight: frame.height, header: field.isHidden ? 0 : Self.style.header, rows: shown)
    }

    func place(height: CGFloat) {
        field.frame = NSRect(x: 16, y: height - Self.style.pad - Self.style.header + 6, width: Self.style.width - 32, height: 22)
        let header = field.isHidden ? 0 : Self.style.header
        for (index, row) in rows.enumerated() {
            row.root.frame = Self.style.rowFrame(index, panelHeight: height, header: header)
        }
    }

    private static func thumbnail(_ url: URL) -> NSImage? {
        let height = style.iconRect.height
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: Int(height * 8),
              ] as CFDictionary), image.height > 0 else { return nil }
        let width = height * CGFloat(image.width) / CGFloat(image.height)
        return NSImage(cgImage: image, size: NSSize(width: min(width, 200).rounded(), height: height))
    }
}

final class ClipPanel: NSPanel, NSWindowDelegate {
    private let store: Clipboard
    private let list = ClipContent()
    private var clips: [Clip] = []
    private var query = ""
    private var selected = 0
    private var offset = 0
    private var caller: NSRunningApplication?
    private var anchor = NSPoint.zero

    override var canBecomeKey: Bool {
        true
    }

    init(clipboard: Clipboard) {
        store = clipboard
        super.init(contentRect: NSRect(x: 0, y: 0, width: ClipContent.style.width,
                                       height: ClipContent.height(rows: 0, header: false)),
                   styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        delegate = self
        configureFloatingPanel()
        acceptsMouseMovedEvents = true
        contentView = list
    }

    func toggle() {
        isVisible ? dismiss() : present()
    }

    private func present() {
        query = ""
        selected = 0
        caller = NSWorkspace.shared.frontmostApplication
        anchor = NSEvent.mouseLocation
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    private func dismiss() {
        guard isVisible else { return }
        dismissAndHide()
    }

    func windowDidResignKey(_: Notification) {
        dismiss()
    }

    private func refresh() {
        clips = store.recent(query)
        selected = min(selected, max(0, clips.count - 1))
        offset = 0
        place(anchor, height: draw())
    }

    @discardableResult
    private func draw() -> CGFloat {
        list.render(Array(clips[offset ..< min(clips.count, offset + ClipContent.style.rows)]),
                    query: query, selected: selected - offset, image: store.image)
    }

    private func place(_ corner: NSPoint, height: CGFloat) {
        guard let screen = screenFor(point: corner) else { return }
        let visible = screen.visibleFrame
        let width = ClipContent.style.width
        let x = min(max(corner.x, visible.minX + 8), max(visible.minX + 8, visible.maxX - width - 8))
        let y = min(max(corner.y - height, visible.minY + 8), max(visible.minY + 8, visible.maxY - height - 8))
        setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: width, height: height), display: true)
        list.place(height: height)
    }

    private func paste(_ index: Int) {
        guard clips.indices.contains(index) else { return }
        dismiss()
        guard Tile.granted() else { return }
        store.paste(store.offer(clips[index].digest), into: caller)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isVisible, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let digit = event.charactersIgnoringModifiers.flatMap(Int.init),
              (1 ... ClipContent.style.rows).contains(digit)
        else { return super.performKeyEquivalent(with: event) }
        paste(offset + digit - 1)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.isDisjoint(with: [.command, .control]) else { return super.keyDown(with: event) }
        switch keyAction(event) {
        case .dismiss:
            dismiss()
        case .submit:
            paste(selected)
        case .down:
            move(1)
        case .up:
            move(-1)
        case .backspace:
            query = String(query.dropLast())
            refresh()
        case .type(let text):
            query += text
            refresh()
        case nil:
            break
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard let index = list.index(at: list.convert(event.locationInWindow, from: nil)),
              selected != offset + index else { return }
        selected = offset + index
        draw()
    }

    override func mouseDown(with event: NSEvent) {
        guard let index = list.index(at: list.convert(event.locationInWindow, from: nil)) else { return }
        paste(offset + index)
    }

    override func scrollWheel(with event: NSEvent) {
        let step = event.scrollingDeltaY > 1 ? -1 : (event.scrollingDeltaY < -1 ? 1 : 0)
        let rows = ClipContent.style.rows
        guard step != 0, clips.count > rows else { return }
        offset = min(max(0, offset + step), clips.count - rows)
        selected = min(max(selected, offset), offset + rows - 1)
        draw()
    }

    private func move(_ delta: Int) {
        guard !clips.isEmpty else { return }
        selected = (selected + delta + clips.count) % clips.count
        offset = min(max(offset, selected - ClipContent.style.rows + 1), selected)
        offset = min(offset, max(0, clips.count - ClipContent.style.rows))
        draw()
    }
}
