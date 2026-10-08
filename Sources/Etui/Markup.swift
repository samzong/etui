import AppKit

enum Mark: Equatable {
    case rect(NSRect)
    case arrow(NSPoint, NSPoint)
}

enum MarkTool: String, CaseIterable {
    case rect = "Rectangle"
    case arrow = "Arrow"

    var symbol: String {
        switch self {
        case .rect: "rectangle"
        case .arrow: "arrow.up.right"
        }
    }

    func mark(from start: NSPoint, to end: NSPoint) -> Mark {
        switch self {
        case .rect:
            .rect(NSRect(x: min(start.x, end.x), y: min(start.y, end.y),
                         width: abs(end.x - start.x), height: abs(end.y - start.y)))
        case .arrow:
            .arrow(start, end)
        }
    }
}

enum Markup {
    static let color = NSColor.systemRed
    static let width: CGFloat = 3

    static func render(_ marks: [Mark], in context: CGContext, lineWidth: CGFloat) {
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for mark in marks {
            switch mark {
            case .rect(let rect):
                context.stroke(rect)
            case .arrow(let start, let end):
                let angle = atan2(end.y - start.y, end.x - start.x)
                let head = lineWidth * 4
                context.move(to: start)
                context.addLine(to: end)
                for side in [-1.0, 1.0] {
                    let turn = angle + .pi + side * .pi / 6
                    context.move(to: end)
                    context.addLine(to: CGPoint(x: end.x + cos(turn) * head, y: end.y + sin(turn) * head))
                }
                context.strokePath()
            }
        }
        context.restoreGState()
    }

    static func export(_ image: CGImage, marks: [Mark], lineWidth: CGFloat) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        render(marks, in: context, lineWidth: lineWidth)
        return context.makeImage()
    }
}

@MainActor
final class MarkCanvas: NSView {
    let image: CGImage
    let unit: CGFloat
    let lineWidth: CGFloat
    var tool = MarkTool.rect
    private(set) var marks: [Mark] = []
    private var start: NSPoint?
    private var pending: Mark?
    private let history = UndoManager()

    init(image: CGImage, unit: CGFloat, lineWidth: CGFloat) {
        self.image = image
        self.unit = unit
        self.lineWidth = lineWidth
        history.groupsByEvent = false
        super.init(frame: NSRect(x: 0, y: 0, width: CGFloat(image.width) * unit, height: CGFloat(image.height) * unit))
    }

    required init?(coder _: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var undoManager: UndoManager? { history }

    var exported: CGImage? {
        Markup.export(image, marks: marks, lineWidth: lineWidth)
    }

    private func pixel(_ event: NSEvent) -> NSPoint {
        let point = convert(event.locationInWindow, from: nil)
        return NSPoint(x: min(max(point.x / unit, 0), CGFloat(image.width)),
                       y: min(max(point.y / unit, 0), CGFloat(image.height)))
    }

    override func mouseDown(with event: NSEvent) {
        start = pixel(event)
        pending = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        pending = tool.mark(from: start, to: pixel(event))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            start = nil
            pending = nil
            needsDisplay = true
        }
        guard let start else { return }
        let end = pixel(event)
        guard hypot(end.x - start.x, end.y - start.y) >= lineWidth * 2 else { return }
        history.beginUndoGrouping()
        add(tool.mark(from: start, to: end))
        history.endUndoGrouping()
    }

    private func add(_ mark: Mark) {
        marks.append(mark)
        history.registerUndo(withTarget: self) { $0.remove() }
        needsDisplay = true
    }

    private func remove() {
        guard let mark = marks.popLast() else { return }
        history.registerUndo(withTarget: self) { $0.add(mark) }
        needsDisplay = true
    }

    @objc func undo(_: Any?) {
        history.undo()
    }

    @objc func redo(_: Any?) {
        history.redo()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { window?.cancelOperation(nil) }
        if event.keyCode == 36 { (window as? ShotPanel)?.onSubmit?() }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .high
        context.draw(image, in: bounds)
        context.saveGState()
        context.scaleBy(x: unit, y: unit)
        Markup.render(marks + (pending.map { [$0] } ?? []), in: context, lineWidth: lineWidth)
        context.restoreGState()
    }
}

@MainActor
final class MarkEditor {
    let panel: ShotPanel
    let canvas: MarkCanvas

    init(image: CGImage, scale: CGFloat, visible: NSRect) {
        let natural = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let zoom = min(1, (visible.width - 48) / natural.width, (visible.height - 108) / natural.height)
        canvas = MarkCanvas(image: image, unit: zoom / scale, lineWidth: Markup.width * scale)
        let width = max(canvas.frame.width, 232) + 24
        let height = canvas.frame.height + 60
        panel = ShotPanel(size: NSSize(width: width, height: height))
        panel.setFrameOrigin(NSPoint(x: visible.midX - width / 2, y: visible.midY - height / 2))
        panel.title = "Markup"
        canvas.frame.origin = NSPoint(x: (width - canvas.frame.width) / 2, y: 12)
        for (index, item) in MarkTool.allCases.enumerated() {
            let button = Tap(symbol: item.symbol, flat: true) { [weak panel, weak canvas] in
                canvas?.tool = item
                for button in panel?.contentView?.subviews.compactMap({ $0 as? Tap }) ?? [] where button.tag > 0 {
                    let selected = MarkTool.allCases[button.tag - 1] == item
                    button.state = selected ? .on : .off
                    button.contentTintColor = selected ? .controlAccentColor : .secondaryLabelColor
                }
            }
            button.tag = index + 1
            button.setButtonType(.pushOnPushOff)
            button.state = item == canvas.tool ? .on : .off
            button.frame = NSRect(x: 12 + CGFloat(index) * 36, y: height - 40, width: 32, height: 32)
            button.contentTintColor = item == canvas.tool ? .controlAccentColor : .secondaryLabelColor
            button.keyEquivalent = String(index + 1)
            button.keyEquivalentModifierMask = .command
            button.toolTip = "\(item.rawValue) · ⌘\(index + 1)"
            button.setAccessibilityLabel(item.rawValue)
            panel.contentView?.addSubview(button)
        }
        let undo = Tap(symbol: "arrow.uturn.backward", flat: true) { [weak canvas] in canvas?.undo(nil) }
        undo.frame = NSRect(x: 84, y: height - 40, width: 32, height: 32)
        undo.toolTip = "Undo · ⌘Z"
        undo.setAccessibilityLabel("Undo markup")
        let divider = NSBox(frame: NSRect(x: width - 94, y: height - 36, width: 1, height: 24))
        divider.boxType = .separator
        let cancel = Tap(symbol: "xmark", flat: true) { [weak panel] in panel?.onCancel?() }
        cancel.frame = NSRect(x: width - 80, y: height - 40, width: 32, height: 32)
        cancel.toolTip = "Cancel · Esc"
        cancel.setAccessibilityLabel("Cancel markup")
        let submit = Tap(symbol: "doc.on.doc", flat: true) { [weak panel] in panel?.onSubmit?() }
        submit.frame = NSRect(x: width - 44, y: height - 40, width: 32, height: 32)
        submit.contentTintColor = .controlAccentColor
        submit.toolTip = "Copy · Return"
        submit.setAccessibilityLabel("Copy screenshot")
        [undo, divider, cancel, submit, canvas].forEach { panel.contentView?.addSubview($0) }
    }
}
