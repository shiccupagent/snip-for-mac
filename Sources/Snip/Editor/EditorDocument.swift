import AppKit
import SwiftUI

enum Tool: String, CaseIterable, Identifiable {
    case pen, highlighter, eraser, arrow, line, rect, ellipse, text, redact, crop

    var id: String { rawValue }

    static let shapes: [Tool] = [.arrow, .line, .rect, .ellipse]
    var isShape: Bool { Tool.shapes.contains(self) }

    var title: String {
        switch self {
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .eraser: "Eraser"
        case .arrow: "Arrow"
        case .line: "Line"
        case .rect: "Rectangle"
        case .ellipse: "Oval"
        case .text: "Text"
        case .redact: "Redact"
        case .crop: "Crop"
        }
    }

    var icon: String {
        switch self {
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .eraser: "eraser"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .rect: "rectangle"
        case .ellipse: "circle"
        case .text: "textformat"
        case .redact: "eye.slash"
        case .crop: "crop"
        }
    }

    /// Whether the tool has a color and size you can change.
    var hasStyle: Bool { self != .eraser && self != .crop && self != .redact }

    /// Shapes share one color and size, like Snipping Tool's shape picker.
    var styleKey: Tool { isShape ? .arrow : self }

    var sizeRange: ClosedRange<CGFloat> {
        switch styleKey {
        case .highlighter: 6...48
        case .text: 10...96
        default: 1...24
        }
    }
}

struct Annotation: Identifiable {
    var id = UUID()
    var tool: Tool
    /// Image pixel coordinates, top-left origin. Shapes use [start, end]; text uses [topLeft].
    var points: [CGPoint]
    var color: NSColor
    /// Stroke width in image pixels.
    var width: CGFloat
    var text = ""
    /// Font size in image pixels.
    var fontSize: CGFloat = 0
}

@MainActor
final class EditorDocument: ObservableObject {
    struct Snapshot {
        var annotations: [Annotation]
        var crop: CGRect
    }

    let image: CGImage
    /// Pixels per point of the display the snip came from.
    let scale: CGFloat
    var fileURL: URL?

    @Published var annotations: [Annotation] = []
    @Published var crop: CGRect
    @Published var pendingCrop: CGRect
    @Published private(set) var tool: Tool = .pen
    @Published private(set) var lastShape: Tool = .arrow
    @Published private var colors: [Tool: NSColor] = [
        .pen: EditorDocument.srgb(.systemRed),
        .highlighter: EditorDocument.srgb(.systemYellow),
        .arrow: EditorDocument.srgb(.systemRed),
        .text: EditorDocument.srgb(.systemRed),
    ]
    @Published private var sizes: [Tool: CGFloat] = [.pen: 3, .highlighter: 16, .arrow: 4, .text: 22]
    @Published var isEditingText = false
    @Published var status: String?
    @Published private var undoStack: [Snapshot] = []
    @Published private var redoStack: [Snapshot] = []

    private var toolBeforeCrop: Tool = .pen
    private var statusTask: Task<Void, Never>?
    var onEdited: (() -> Void)?

    init(image: CGImage, scale: CGFloat, fileURL: URL?) {
        self.image = image
        self.scale = max(scale, 1)
        self.fileURL = fileURL
        let full = CGRect(origin: .zero, size: image.pixelSize)
        crop = full
        pendingCrop = full
    }

    nonisolated static func srgb(_ c: NSColor) -> NSColor { c.usingColorSpace(.sRGB) ?? c }

    var fullBounds: CGRect { CGRect(origin: .zero, size: image.pixelSize) }
    var canUndo: Bool { !undoStack.isEmpty }

    /// Undo depth when the image was last saved; markup made after that isn't on disk anywhere.
    private var savedDepth = 0
    var hasUnsavedMarkup: Bool { undoStack.count != savedDepth }
    func markSaved() { savedDepth = undoStack.count }
    var canRedo: Bool { !redoStack.isEmpty }

    // MARK: Tools & style

    func select(_ t: Tool) {
        if tool == .crop && t != .crop { applyCrop() }
        if t == .crop && tool != .crop {
            toolBeforeCrop = tool
            pendingCrop = crop
        }
        if t.isShape { lastShape = t }
        tool = t
    }

    func color(for t: Tool) -> NSColor { colors[t.styleKey] ?? .systemRed }
    func setColor(_ c: NSColor, for t: Tool) { colors[t.styleKey] = EditorDocument.srgb(c) }
    func size(for t: Tool) -> CGFloat { sizes[t.styleKey] ?? 3 }
    func setSize(_ s: CGFloat, for t: Tool) { sizes[t.styleKey] = s }
    func pixelSize(for t: Tool) -> CGFloat { size(for: t) * scale }

    // MARK: Undo

    func pushUndo() {
        undoStack.append(Snapshot(annotations: annotations, crop: crop))
        if undoStack.count > 300 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func commit(_ change: (EditorDocument) -> Void) {
        pushUndo()
        change(self)
        edited()
    }

    func edited() { onEdited?() }

    func undo() {
        guard let s = undoStack.popLast() else { return }
        redoStack.append(Snapshot(annotations: annotations, crop: crop))
        restore(s)
    }

    func redo() {
        guard let s = redoStack.popLast() else { return }
        undoStack.append(Snapshot(annotations: annotations, crop: crop))
        restore(s)
    }

    private func restore(_ s: Snapshot) {
        annotations = s.annotations
        crop = s.crop
        pendingCrop = s.crop
        edited()
    }

    // MARK: Crop

    private func applyCrop() {
        let r = pendingCrop.standardized.integral.intersection(fullBounds)
        guard r.width >= 4, r.height >= 4, r != crop else {
            pendingCrop = crop
            return
        }
        commit { $0.crop = r }
    }

    func finishCrop() { select(toolBeforeCrop) }

    func cancelCrop() {
        pendingCrop = crop
        tool = toolBeforeCrop
    }

    func resetCrop() { pendingCrop = fullBounds }

    // MARK: Output

    func render() -> CGImage? { Renderer.export(self) }

    func flash(_ message: String) {
        status = message
        statusTask?.cancel()
        statusTask = Task {
            try? await Task.sleep(for: .seconds(1.8))
            if !Task.isCancelled { status = nil }
        }
    }
}
