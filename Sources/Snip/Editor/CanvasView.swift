import AppKit
import Combine

/// The drawing surface in the editor window.
@MainActor
final class CanvasView: NSView, NSTextFieldDelegate {
    let doc: EditorDocument
    var onCopy: (() -> Void)?

    private var cancellables = Set<AnyCancellable>()
    private var live: Annotation?
    private var dragStart: CGPoint?
    private var erasedThisDrag = false

    private var textField: NSTextField?
    private var textOrigin: CGPoint = .zero
    private var editingID: UUID?

    private struct CropDrag {
        var left = false, right = false, top = false, bottom = false
        var move = false
        var startRect: CGRect
        var startPoint: CGPoint
    }
    private var cropDrag: CropDrag?

    init(doc: EditorDocument) {
        self.doc = doc
        super.init(frame: .zero)
        doc.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.needsDisplay = true
                self.window?.invalidateCursorRects(for: self)
            }
        }.store(in: &cancellables)
        doc.$tool.removeDuplicates().sink { [weak self] _ in
            Task { @MainActor in self?.commitText() }
        }.store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Layout & coordinates

    /// The part of the image on screen: the crop, or the whole image while cropping.
    private var region: CGRect { doc.tool == .crop ? doc.fullBounds : doc.crop }

    private var layout: (rect: CGRect, scale: CGFloat) {
        let region = self.region
        let avail = bounds.insetBy(dx: 28, dy: 28)
        guard region.width > 0, region.height > 0, avail.width > 0, avail.height > 0 else {
            return (.zero, 1)
        }
        let s = min(1 / doc.scale, avail.width / region.width, avail.height / region.height)
        let size = CGSize(width: region.width * s, height: region.height * s)
        let origin = CGPoint(x: (bounds.midX - size.width / 2).rounded(), y: (bounds.midY - size.height / 2).rounded())
        return (CGRect(origin: origin, size: size), s)
    }

    private func toImage(_ p: CGPoint) -> CGPoint {
        let (r, s) = layout
        return CGPoint(x: (p.x - r.minX) / s + region.minX, y: (p.y - r.minY) / s + region.minY)
    }

    private func toView(_ p: CGPoint) -> CGPoint {
        let (r, s) = layout
        return CGPoint(x: (p.x - region.minX) * s + r.minX, y: (p.y - region.minY) * s + r.minY)
    }

    private func toView(_ rect: CGRect) -> CGRect {
        let o = toView(rect.origin)
        let s = layout.scale
        return CGRect(x: o.x, y: o.y, width: rect.width * s, height: rect.height * s)
    }

    private func point(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func resetCursorRects() {
        let r = layout.rect
        switch doc.tool {
        case .text: addCursorRect(r, cursor: .iBeam)
        default: addCursorRect(r, cursor: .crosshair)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        positionTextField()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()

        let (r, s) = layout
        guard r.width > 0 else { return }

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 14, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(r)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.clip(to: r)
        ctx.translateBy(x: r.minX, y: r.minY)
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -region.minX, y: -region.minY)
        ctx.interpolationQuality = .high
        var items = doc.annotations
        if let editingID { items.removeAll { $0.id == editingID } }
        if let live { items.append(live) }
        Renderer.renderScene(in: ctx, image: doc.image, annotations: items)
        ctx.restoreGState()

        if doc.tool == .crop { drawCropUI(ctx) }
    }

    private func drawCropUI(_ ctx: CGContext) {
        let full = layout.rect
        let c = toView(doc.pendingCrop.standardized)

        let dim = CGMutablePath()
        dim.addRect(full)
        dim.addRect(c)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        ctx.addPath(dim)
        ctx.fillPath(using: .evenOdd)

        // Rule of thirds
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.4).cgColor)
        ctx.setLineWidth(1)
        for i in 1...2 {
            let x = c.minX + c.width * CGFloat(i) / 3
            let y = c.minY + c.height * CGFloat(i) / 3
            ctx.move(to: CGPoint(x: x, y: c.minY)); ctx.addLine(to: CGPoint(x: x, y: c.maxY))
            ctx.move(to: CGPoint(x: c.minX, y: y)); ctx.addLine(to: CGPoint(x: c.maxX, y: y))
        }
        ctx.strokePath()

        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(c)

        // Corner brackets, like Snipping Tool's crop handles
        let len: CGFloat = 18
        ctx.setLineWidth(4)
        ctx.setLineCap(.square)
        for (corner, dx, dy) in [
            (CGPoint(x: c.minX, y: c.minY), 1.0, 1.0), (CGPoint(x: c.maxX, y: c.minY), -1.0, 1.0),
            (CGPoint(x: c.minX, y: c.maxY), 1.0, -1.0), (CGPoint(x: c.maxX, y: c.maxY), -1.0, -1.0),
        ] {
            ctx.move(to: CGPoint(x: corner.x + len * dx, y: corner.y))
            ctx.addLine(to: corner)
            ctx.addLine(to: CGPoint(x: corner.x, y: corner.y + len * dy))
        }
        ctx.strokePath()
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        if textField != nil {
            window?.makeFirstResponder(self)
            return
        }
        window?.makeFirstResponder(self)
        let v = point(event)
        let p = toImage(v)
        switch doc.tool {
        case .pen, .highlighter:
            live = Annotation(tool: doc.tool, points: [p], color: doc.color(for: doc.tool), width: doc.pixelSize(for: doc.tool))
        case .arrow, .line, .rect, .ellipse, .redact:
            dragStart = p
            live = Annotation(tool: doc.tool, points: [p, p], color: doc.color(for: doc.tool), width: doc.pixelSize(for: doc.tool))
        case .eraser:
            erasedThisDrag = false
            erase(at: p)
        case .text:
            beginText(at: p)
        case .crop:
            beginCropDrag(at: v)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let v = point(event)
        let p = toImage(v)
        switch doc.tool {
        case .pen, .highlighter:
            guard var a = live, let last = a.points.last else { return }
            if hypot(p.x - last.x, p.y - last.y) * layout.scale > 0.75 {
                a.points.append(p)
                live = a
            }
        case .arrow, .line, .rect, .ellipse, .redact:
            guard var a = live, let start = dragStart else { return }
            a.points[1] = event.modifierFlags.contains(.shift) ? constrained(start, p, tool: doc.tool) : p
            live = a
        case .eraser:
            erase(at: p)
        case .crop:
            updateCropDrag(to: v)
        case .text:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            live = nil
            dragStart = nil
            cropDrag = nil
            needsDisplay = true
        }
        guard let a = live else { return }
        if a.tool != .pen && a.tool != .highlighter {
            let r = Renderer.rect(of: a)
            let minSize = 3 / layout.scale
            guard hypot(r.width, r.height) >= minSize else { return }
        }
        doc.commit { $0.annotations.append(a) }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: // Return / Enter
            if doc.tool == .crop { doc.finishCrop() } else { super.keyDown(with: event) }
        case 53: // Escape
            if doc.tool == .crop { doc.cancelCrop() } else { super.keyDown(with: event) }
        default:
            super.keyDown(with: event)
        }
    }

    private func constrained(_ start: CGPoint, _ end: CGPoint, tool: Tool) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        if tool == .line || tool == .arrow {
            let step = CGFloat.pi / 4
            let angle = (atan2(dy, dx) / step).rounded() * step
            let len = hypot(dx, dy)
            return CGPoint(x: start.x + cos(angle) * len, y: start.y + sin(angle) * len)
        }
        let side = max(abs(dx), abs(dy))
        return CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
    }

    // MARK: Eraser

    private func erase(at p: CGPoint) {
        let tolerance = 6 / layout.scale
        guard let index = doc.annotations.lastIndex(where: { Renderer.hitTest($0, at: p, tolerance: tolerance) }) else { return }
        if !erasedThisDrag {
            doc.pushUndo()
            erasedThisDrag = true
        }
        doc.annotations.remove(at: index)
        doc.edited()
    }

    // MARK: Text

    private func beginText(at p: CGPoint) {
        var text = ""
        var color = doc.color(for: .text)
        var fontSize = doc.pixelSize(for: .text)
        textOrigin = p
        editingID = nil
        if let existing = doc.annotations.last(where: { $0.tool == .text && Renderer.textRect($0).contains(p) }) {
            editingID = existing.id
            text = existing.text
            color = existing.color
            fontSize = existing.fontSize
            textOrigin = existing.points.first ?? p
        }

        let field = NSTextField(string: text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = color
        field.font = NSFont.systemFont(ofSize: fontSize * layout.scale, weight: .semibold)
        field.delegate = self
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.wantsLayer = true
        field.layer?.borderWidth = 1
        field.layer?.borderColor = NSColor.controlAccentColor.cgColor
        field.layer?.cornerRadius = 3
        addSubview(field)
        textField = field
        positionTextField()
        window?.makeFirstResponder(field)
        doc.isEditingText = true
        needsDisplay = true
    }

    private func positionTextField() {
        guard let field = textField else { return }
        field.sizeToFit()
        let origin = toView(textOrigin)
        field.frame = CGRect(x: origin.x - 2, y: origin.y, width: max(field.frame.width + 12, 60), height: field.frame.height)
    }

    func controlTextDidChange(_ obj: Notification) {
        positionTextField()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitText()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            removeTextField()
            return true
        }
        return false
    }

    private func commitText() {
        guard let field = textField else { return }
        let str = field.stringValue
        let id = editingID
        let origin = textOrigin
        let color = field.textColor ?? doc.color(for: .text)
        let fontSize = (field.font?.pointSize ?? 20) / layout.scale
        removeTextField()

        if let id, let index = doc.annotations.firstIndex(where: { $0.id == id }) {
            guard str != doc.annotations[index].text else { return }
            doc.commit { d in
                if str.isEmpty { d.annotations.remove(at: index) } else { d.annotations[index].text = str }
            }
        } else if !str.trimmingCharacters(in: .whitespaces).isEmpty {
            let a = Annotation(tool: .text, points: [origin], color: color, width: 0, text: str, fontSize: fontSize)
            doc.commit { $0.annotations.append(a) }
        }
    }

    private func removeTextField() {
        guard let field = textField else { return }
        textField = nil
        editingID = nil
        field.delegate = nil
        field.removeFromSuperview()
        doc.isEditingText = false
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    // MARK: Crop

    private func beginCropDrag(at v: CGPoint) {
        let c = toView(doc.pendingCrop.standardized)
        let grab: CGFloat = 12
        var drag = CropDrag(startRect: doc.pendingCrop.standardized, startPoint: toImage(v))
        let nearLeft = abs(v.x - c.minX) < grab, nearRight = abs(v.x - c.maxX) < grab
        let nearTop = abs(v.y - c.minY) < grab, nearBottom = abs(v.y - c.maxY) < grab
        let withinX = v.x > c.minX - grab && v.x < c.maxX + grab
        let withinY = v.y > c.minY - grab && v.y < c.maxY + grab
        drag.left = nearLeft && withinY
        drag.right = nearRight && withinY && !drag.left
        drag.top = nearTop && withinX
        drag.bottom = nearBottom && withinX && !drag.top
        if !(drag.left || drag.right || drag.top || drag.bottom) {
            if c.contains(v) {
                drag.move = true
            } else {
                // Start a brand-new crop rectangle from here.
                let p = clampToImage(toImage(v))
                drag.startRect = CGRect(origin: p, size: .zero)
                drag.startPoint = p
                drag.right = true
                drag.bottom = true
            }
        }
        cropDrag = drag
    }

    private func updateCropDrag(to v: CGPoint) {
        guard let d = cropDrag else { return }
        let p = clampToImage(toImage(v))
        let full = doc.fullBounds
        var r = d.startRect
        if d.move {
            r.origin.x = min(max(d.startRect.minX + p.x - d.startPoint.x, 0), full.width - r.width)
            r.origin.y = min(max(d.startRect.minY + p.y - d.startPoint.y, 0), full.height - r.height)
        } else {
            var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
            if d.left { minX = p.x }
            if d.right { maxX = p.x }
            if d.top { minY = p.y }
            if d.bottom { maxY = p.y }
            r = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
        }
        doc.pendingCrop = r.intersection(full)
    }

    private func clampToImage(_ p: CGPoint) -> CGPoint {
        let full = doc.fullBounds
        return CGPoint(x: min(max(p.x, 0), full.width), y: min(max(p.y, 0), full.height))
    }

    // MARK: Edit menu

    @objc func copy(_ sender: Any?) { onCopy?() }
    @objc func undo(_ sender: Any?) { doc.undo() }
    @objc func redo(_ sender: Any?) { doc.redo() }
}
