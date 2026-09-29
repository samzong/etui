import AppKit
import Carbon

enum TransMetrics {
    static let width: CGFloat = 440
    static let pad: CGFloat = 12
    static let gap: CGFloat = 10
    static let blockGap: CGFloat = 8
    static let head: CGFloat = 36
    static let bodyBottom: CGFloat = 10
    static let actions: CGFloat = 28
    static let body = bodyBottom + actions
    static let sourceInset: CGFloat = 12
    static let radius: CGFloat = 12
    static let sourceLine: CGFloat = 23
    static let line: CGFloat = 21
    static let minLines: CGFloat = 3
    static let maxLines: CGFloat = 10
    static let sourceText = width - pad * 2 - sourceInset * 2 - 24
    static let blockText = width - pad * 2 - 24

    static func sourceHeight(_ content: CGFloat) -> CGFloat {
        min(max(content, sourceLine * 3), sourceLine * 7) + sourceInset * 2
    }

    static func blockHeight(_ output: CGFloat, open: Bool) -> CGFloat {
        head + (open ? output + body : 0)
    }

    static func panelHeight(source: CGFloat, outputs: [CGFloat], open: [Bool]) -> CGFloat {
        pad * 2 + source + (outputs.isEmpty ? 0 : gap)
            + CGFloat(max(0, outputs.count - 1)) * blockGap
            + zip(outputs, open).reduce(0) { $0 + blockHeight($1.0, open: $1.1) }
    }

    static func solve(source: CGFloat, blocks: [CGFloat?], limit: CGFloat) -> (panel: CGFloat, outputs: [CGFloat]) {
        let open = blocks.map { $0 != nil }
        var outputs = blocks.map { $0.map { max(line, min($0, line * maxLines)) } ?? 0 }
        let floors = outputs.map { min($0, line * minLines) }
        let wanted = panelHeight(source: source, outputs: outputs, open: open)
        let slack = zip(outputs, floors).reduce(0) { $0 + $1.0 - $1.1 }
        guard wanted > limit, slack > 0 else { return (wanted, outputs) }
        let cut = min(wanted - limit, slack)
        for index in outputs.indices {
            let room = outputs[index] - floors[index]
            outputs[index] -= (room / slack * cut).rounded(.up)
            outputs[index] = max(floors[index], outputs[index])
        }
        return (panelHeight(source: source, outputs: outputs, open: open), outputs)
    }
}

enum BlockTap {
    case fold
    case copy
    case insert
}

@MainActor
private func wellBox(dark: CGFloat, light: CGFloat) -> NSBox {
    let box = NSBox()
    box.boxType = .custom
    box.titlePosition = .noTitle
    box.borderWidth = 0
    box.cornerRadius = TransMetrics.radius
    box.contentViewMargins = .zero
    box.fillColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: dark) : NSColor(white: 0, alpha: light)
    }
    return box
}

@MainActor
private final class TextWell {
    let scroll = NSScrollView()
    let view = NSTextView()

    init(size: CGFloat, editable: Bool) {
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = view
        view.drawsBackground = false
        view.font = .systemFont(ofSize: size)
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.isSelectable = true
        view.isEditable = editable
        guard editable else { return }
        view.isRichText = false
        view.allowsUndo = true
        view.textColor = .labelColor
        view.insertionPointColor = .controlAccentColor
    }

    func height(_ width: CGFloat) -> CGFloat {
        guard let font = view.font else { return 0 }
        guard !view.string.isEmpty else { return font.ascender - font.descender }
        return ceil(NSAttributedString(string: view.string, attributes: [.font: font])
            .boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
    }

    func place(_ frame: NSRect) {
        scroll.frame = frame
        let width = scroll.contentSize.width
        view.minSize = NSSize(width: width, height: 0)
        view.maxSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        view.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        view.frame = NSRect(x: 0, y: 0, width: width, height: max(frame.height, height(width)))
    }
}

private func display(_ value: Translation?) -> (text: String, color: NSColor, ready: Bool) {
    switch value {
    case .done(let text): (text, .labelColor, true)
    case .failed(let message): (message, .systemRed, false)
    case .pending: ("Translating…", .tertiaryLabelColor, false)
    case nil: ("Press ⌘⏎ to translate", .tertiaryLabelColor, false)
    }
}

@MainActor
private final class TransBlock {
    let root: NSBox
    private let head: Tap
    private let chevron = NSImageView()
    private let well = TextWell(size: 15, editable: false)
    private let copy: Tap
    private let insert: Tap

    init(name: String, act: @escaping (BlockTap) -> Void) {
        root = wellBox(dark: 0.06, light: 0.035)
        head = Tap(title: name) { act(.fold) }
        copy = Tap(symbol: "doc.on.doc") { act(.copy) }
        insert = Tap(symbol: "arrow.right.square") { act(.insert) }
        copy.setAccessibilityLabel("Copy translation")
        insert.setAccessibilityLabel("Insert translation")
        chevron.imageScaling = .scaleNone
        chevron.contentTintColor = .tertiaryLabelColor
        [head, chevron, well.scroll, copy, insert].forEach { root.contentView?.addSubview($0) }
    }

    func show(_ value: Translation?, open: Bool, insertable: Bool) {
        chevron.image = NSImage(systemSymbolName: open ? "chevron.down" : "chevron.right",
                                accessibilityDescription: nil)
        well.scroll.isHidden = !open
        copy.isHidden = !open
        insert.isHidden = !open || !insertable
        guard open else { return }
        let shown = display(value)
        well.view.string = shown.text
        well.view.textColor = shown.color
        copy.isEnabled = shown.ready
        insert.isEnabled = shown.ready
    }

    var content: CGFloat {
        well.height(TransMetrics.blockText)
    }

    func place(_ frame: NSRect, output extent: CGFloat) {
        root.frame = frame
        let width = frame.width
        head.frame = NSRect(x: 12, y: frame.height - TransMetrics.head, width: width - 36, height: TransMetrics.head)
        chevron.frame = NSRect(x: width - 26, y: frame.height - TransMetrics.head + 11, width: 14, height: 14)
        well.place(NSRect(x: 12, y: TransMetrics.body, width: TransMetrics.blockText, height: extent))
        insert.frame = NSRect(x: width - 38, y: TransMetrics.bodyBottom - 4, width: 26, height: 24)
        copy.frame = NSRect(x: width - (insert.isHidden ? 38 : 66), y: TransMetrics.bodyBottom - 4, width: 26, height: 24)
    }
}

@MainActor
private final class TransContent: NSView {
    let source = TextWell(size: 17, editable: true)
    private let pin: Tap
    private let box: NSBox
    private let glass = GlassPanel(frame: .zero)
    private var blocks: [TransBlock] = []

    init(onPin: @escaping () -> Void) {
        pin = Tap(symbol: "pin", run: onPin)
        box = wellBox(dark: 0.11, light: 0.07)
        super.init(frame: NSRect(x: 0, y: 0, width: TransMetrics.width, height: 200))
        wantsLayer = true
        glass.frame = bounds
        addSubview(glass)
        box.contentView?.addSubview(source.scroll)
        box.contentView?.addSubview(pin)
        addSubview(box)
    }

    required init?(coder _: NSCoder) {
        nil
    }

    func rebuild(styles: [Style], act: @escaping (Int, BlockTap) -> Void) {
        blocks.forEach { $0.root.removeFromSuperview() }
        blocks = styles.enumerated().map { index, style in
            let block = TransBlock(name: style.name) { act(index, $0) }
            addSubview(block.root)
            return block
        }
    }

    func show(pinned: Bool) {
        pin.image = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin", accessibilityDescription: nil)
        pin.setAccessibilityLabel(pinned ? "Unpin translation panel" : "Pin translation panel")
        pin.contentTintColor = pinned ? .controlAccentColor : .tertiaryLabelColor
    }

    func render(opened: Set<Int>, value: (Int) -> Translation?, insertable: Bool, limit: CGFloat) -> CGFloat {
        for (index, block) in blocks.enumerated() {
            block.show(value(index), open: opened.contains(index), insertable: insertable)
        }
        let well = TransMetrics.sourceHeight(source.height(TransMetrics.sourceText))
        let (panel, outputs) = TransMetrics.solve(
            source: well,
            blocks: blocks.indices.map { opened.contains($0) ? blocks[$0].content : nil },
            limit: limit)
        frame = NSRect(x: 0, y: 0, width: TransMetrics.width, height: panel)
        glass.frame = bounds
        let inner = TransMetrics.width - TransMetrics.pad * 2
        box.frame = NSRect(x: TransMetrics.pad, y: panel - TransMetrics.pad - well, width: inner, height: well)
        source.place(NSRect(x: TransMetrics.sourceInset, y: TransMetrics.sourceInset,
                            width: TransMetrics.sourceText, height: well - TransMetrics.sourceInset * 2))
        pin.frame = NSRect(x: inner - 34, y: well - 32, width: 24, height: 24)
        var top = panel - TransMetrics.pad - well - TransMetrics.gap
        for (index, block) in blocks.enumerated() {
            let tall = TransMetrics.blockHeight(outputs[index], open: opened.contains(index))
            block.place(NSRect(x: TransMetrics.pad, y: top - tall, width: inner, height: tall), output: outputs[index])
            top -= tall + TransMetrics.blockGap
        }
        return panel
    }
}

final class TransPanel: NSPanel, NSWindowDelegate, NSTextViewDelegate {
    private let clipboard: Clipboard
    private lazy var content = TransContent { [weak self] in self?.togglePin() }
    private var translator = Translator()
    private var opened: Set<Int> = []
    private var caller: NSRunningApplication?
    private var replaceable = false
    private var anchor = NSPoint.zero
    private var pinned = false
    private var dragged = false
    private var placing = false

    override var canBecomeKey: Bool {
        true
    }

    init(clipboard: Clipboard) {
        self.clipboard = clipboard
        super.init(contentRect: NSRect(x: 0, y: 0, width: TransMetrics.width, height: 200),
                   styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        delegate = self
        configureFloatingPanel()
        content.source.view.delegate = self
        setPinned(false)
        isMovableByWindowBackground = true
        contentView = content
    }

    required init?(coder _: NSCoder) {
        nil
    }

    func fromSelection() {
        guard !isVisible || pinned else { return dismiss() }
        let origin = NSWorkspace.shared.frontmostApplication
        clipboard.capture { [weak self] text in
            self?.present(text, caller: origin, replaceable: !text.isEmpty)
        }
    }

    func fromInput() {
        guard !isVisible || pinned else { return dismiss() }
        present("", caller: NSWorkspace.shared.frontmostApplication, replaceable: false)
    }

    private func present(_ text: String, caller origin: NSRunningApplication?, replaceable replace: Bool) {
        caller = origin
        replaceable = replace
        if !pinned {
            dragged = false
            anchor = NSEvent.mouseLocation
        }
        translator = Translator()
        content.rebuild(styles: translator.config.styles) { [weak self] index, tap in
            self?.act(index, tap)
        }
        opened = trim(text).isEmpty ? [] : [0]
        content.source.view.string = text
        translator.retarget(text)
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(content.source.view)
        content.source.view.selectAll(nil)
        translate()
    }

    private func dismiss() {
        guard isVisible else { return }
        setPinned(false)
        dismissAndHide()
    }

    func windowDidResignKey(_: Notification) {
        guard !pinned else { return }
        dismiss()
    }

    func windowDidMove(_: Notification) {
        guard !placing, isVisible else { return }
        dragged = true
        anchor = NSPoint(x: frame.midX, y: frame.maxY - 1)
    }

    private func togglePin() {
        setPinned(!pinned)
        makeFirstResponder(content.source.view)
    }

    private func setPinned(_ on: Bool) {
        pinned = on
        collectionBehavior = on ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.moveToActiveSpace, .fullScreenAuxiliary]
        content.show(pinned: on)
    }

    private func translate() {
        translator.retarget(content.source.view.string)
        for index in opened.sorted() {
            translator.start(index) { [weak self] in self?.draw() }
        }
        draw()
    }

    private func draw() {
        guard let screen = screenFor(point: anchor) else { return }
        let visible = screen.visibleFrame
        let x = dragged ? frame.minX : visible.minX + floor((visible.width - TransMetrics.width) / 2)
        let top = dragged ? frame.maxY : visible.maxY - visible.height * 0.20
        let height = content.render(opened: opened, value: { self.translator.value($0) },
                                    insertable: replaceable, limit: top - visible.minY - 16)
        let y = max(visible.minY + 8, top - height)
        placing = true
        setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: TransMetrics.width, height: height), display: true)
        placing = false
    }

    private func act(_ index: Int, _ tap: BlockTap) {
        switch tap {
        case .fold:
            guard opened.remove(index) == nil else {
                translator.retire(index)
                return draw()
            }
            opened.insert(index)
            translate()
        case .copy:
            guard case .done(let text)? = translator.value(index) else { return }
            clipboard.place(text)
        case .insert:
            guard case .done(let text)? = translator.value(index) else { return }
            dismiss()
            guard Tile.granted() else { return }
            clipboard.suspend()
            clipboard.paste(clipboard.place(text), into: caller)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.modifierFlags.contains(.command),
           [kVK_Return, kVK_ANSI_KeypadEnter].contains(Int(event.keyCode)) {
            translate()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func textDidChange(_: Notification) {
        let text = content.source.view.string
        translator.retarget(text)
        if !trim(text).isEmpty, opened.isEmpty {
            opened = [0]
        }
        draw()
    }

    func textView(_: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            guard NSApp.currentEvent?.modifierFlags.contains(.command) == true else { return false }
            translate()
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
        default:
            return false
        }
        return true
    }
}
