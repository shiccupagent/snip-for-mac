import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private static var openControllers: [EditorWindowController] = []

    let doc: EditorDocument
    private let canvas: CanvasView
    private let shareAnchor = AnchorBox()
    private var copyTask: Task<Void, Never>?
    /// The snip as first saved, and the "(marked up)" file kept next to it once there's markup.
    private let originalURL: URL?
    private var markupURL: URL?

    /// `replacing`: the frame of the editor this snip takes over from; the new window opens with
    /// the same top-left corner instead of centred.
    static func open(image: CGImage, scale: CGFloat, fileURL: URL?, replacing frame: NSRect? = nil) {
        let controller = EditorWindowController(doc: EditorDocument(image: image, scale: scale, fileURL: fileURL))
        openControllers.append(controller)
        guard let window = controller.window else { return }
        if let frame { window.setFrameTopLeftPoint(NSPoint(x: frame.minX, y: frame.maxY)) }
        WindowTracker.track(window)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(controller.canvas)
    }

    init(doc: EditorDocument) {
        self.doc = doc
        originalURL = doc.fileURL
        canvas = CanvasView(doc: doc)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        super.init(window: window)

        window.title = doc.fileURL?.deletingPathExtension().lastPathComponent ?? "Snip"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 820, height: 460)

        let actions = EditorActions(
            newSnip: { [weak self] kind, mode, delay in self?.newCapture(kind, mode: mode, delay: delay) },
            copy: { [weak self] in self?.copyToClipboard() },
            save: { [weak self] in self?.save() },
            share: { [weak self] in self?.share() },
            copyText: { [weak self] in self?.copyText() },
            showInFinder: { [weak self] in self?.showInFinder() },
            shareAnchor: shareAnchor
        )
        canvas.onCopy = { [weak self] in self?.copyToClipboard() }
        doc.onEdited = { [weak self] in self?.scheduleAutoCopy() }

        let toolbar = NSHostingView(rootView: EditorToolbar(doc: doc, actions: actions))
        let hud = PassthroughHostingView(rootView: StatusHUD(doc: doc))
        let container = NSView()
        for v in [canvas, toolbar, hud] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: container.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hud.centerXAnchor.constraint(equalTo: canvas.centerXAnchor),
            hud.bottomAnchor.constraint(equalTo: canvas.bottomAnchor, constant: -18),
        ])
        window.contentView = container

        let visible = NSScreen.underMouse.visibleFrame
        let pointSize = CGSize(width: CGFloat(doc.image.width) / doc.scale, height: CGFloat(doc.image.height) / doc.scale)
        let width = min(max(pointSize.width + 72, 860), visible.width * 0.9)
        let height = min(max(pointSize.height + 72 + 92, 520), visible.height * 0.9)
        window.setContentSize(NSSize(width: width, height: height))
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    static func controller(for window: NSWindow) -> EditorWindowController? {
        openControllers.first { $0.window === window }
    }

    /// Closes this editor because a newer snip takes its place (as in Snipping Tool). Markup that
    /// was never saved is kept next to the original as "<name> (marked up).png". Returns the frame.
    func retire() -> NSRect? {
        if doc.hasUnsavedMarkup { _ = keepMarkup() }
        let frame = window?.frame
        window?.close()
        return frame
    }

    func windowWillClose(_ notification: Notification) {
        copyTask?.cancel()
        EditorWindowController.openControllers.removeAll { $0 === self }
    }

    // MARK: Actions

    private func scheduleAutoCopy() {
        guard Prefs.autoCopy else { return }
        copyTask?.cancel()
        copyTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            if !Task.isCancelled { copyToClipboard(silent: true) }
        }
    }

    func copyToClipboard(silent: Bool = false) {
        guard let image = doc.render() else { return }
        Clipboard.copy(image, scale: doc.scale)
        if !silent { doc.flash("Copied to clipboard") }
    }

    private func save() {
        guard let window, let image = doc.render() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = doc.fileURL?.lastPathComponent ?? FileNamer.url(in: FileNamer.tempFolder, prefix: "Snip", ext: "png").lastPathComponent
        panel.directoryURL = doc.fileURL?.deletingLastPathComponent() ?? Prefs.snipFolder
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .OK, let url = panel.url else { return }
                let isJPEG = url.pathExtension.lowercased().hasPrefix("jp")
                let data = isJPEG ? image.jpegData(scale: self.doc.scale) : image.pngData(scale: self.doc.scale)
                do {
                    try data?.write(to: url)
                    self.doc.fileURL = url
                    self.doc.markSaved()
                    self.markupURL = nil
                    self.window?.title = url.deletingPathExtension().lastPathComponent
                    self.doc.flash("Saved")
                } catch {
                    NSAlert(error: error).runModal()
                }
            }
        }
    }

    private func share() {
        guard let image = doc.render(), let data = image.pngData(scale: doc.scale), let anchor = shareAnchor.view else { return }
        let url = FileNamer.url(in: FileNamer.tempFolder, prefix: "Snip", ext: "png")
        guard (try? data.write(to: url)) != nil else { return }
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    private func copyText() {
        guard let image = doc.render() else { return }
        doc.flash("Reading text…")
        Task {
            do {
                let text = try await OCR.recognize(image)
                if text.isEmpty {
                    doc.flash("No text found")
                } else {
                    Clipboard.copyText(text)
                    doc.flash("Text copied to clipboard")
                }
            } catch {
                doc.flash("Couldn't read text")
            }
        }
    }

    /// Writes the snip with its markup next to the original as "<name> (marked up).png" (one file,
    /// rewritten each time, so no pile of copies). Returns it, or nil if it couldn't be written.
    private func keepMarkup() -> URL? {
        guard let image = doc.render(), let data = image.pngData(scale: doc.scale) else { return nil }
        let url = markupURL ?? originalURL.map {
            $0.deletingLastPathComponent().appendingPathComponent("\($0.deletingPathExtension().lastPathComponent) (marked up).png")
        } ?? FileNamer.url(in: Prefs.snipFolder, prefix: "Snip", ext: "png")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            doc.markSaved()
            markupURL = url
            return url
        } catch {
            return nil
        }
    }

    /// Shows the snip's file in Finder, ready to drag anywhere. Markup is written first, so the file
    /// shown is what's on screen.
    private func showInFinder() {
        let url = doc.hasUnsavedMarkup ? keepMarkup() : (markupURL ?? doc.fileURL)
        if let url, FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            try? FileManager.default.createDirectory(at: Prefs.snipFolder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(Prefs.snipFolder)
        }
    }

    private func newCapture(_ kind: CaptureKind, mode: SnipMode, delay: Int) {
        switch kind {
        case .snip: CaptureCoordinator.shared.begin(.snip, delay: delay, mode: mode)
        // A recording's delay is the countdown after Start (Prefs.recordDelay), not before the overlay.
        case .record: CaptureCoordinator.shared.begin(.record, mode: mode)
        }
    }
}

struct EditorActions {
    let newSnip: (CaptureKind, SnipMode, Int) -> Void
    let copy: () -> Void
    let save: () -> Void
    let share: () -> Void
    let copyText: () -> Void
    let showInFinder: () -> Void
    let shareAnchor: AnchorBox
}

private let palette: [NSColor] = [
    .black, .white, .systemGray, .systemBrown,
    .systemRed, .systemOrange, .systemYellow, .systemGreen,
    .systemTeal, .systemBlue, .systemIndigo, .systemPurple,
    .systemPink,
    NSColor(srgbRed: 1, green: 0.84, blue: 0, alpha: 1),
    NSColor(srgbRed: 0, green: 0.8, blue: 1, alpha: 1),
    NSColor(srgbRed: 0.6, green: 1, blue: 0.2, alpha: 1),
].map { EditorDocument.srgb($0) }

private func sameColor(_ a: NSColor, _ b: NSColor) -> Bool {
    guard let x = a.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return false }
    return abs(x.redComponent - y.redComponent) < 0.02
        && abs(x.greenComponent - y.greenComponent) < 0.02
        && abs(x.blueComponent - y.blueComponent) < 0.02
}

/// Two rows, like Snipping Tool: New / mode / delay with Undo, Save, Copy and Share on top,
/// then the markup tools centred underneath.
struct EditorToolbar: View {
    @ObservedObject var doc: EditorDocument
    let actions: EditorActions

    @State private var kind: CaptureKind = .snip
    @State private var mode: SnipMode = Prefs.snipMode
    @State private var delay = 0
    @AppStorage(Prefs.Key.recordDelay) private var recordDelay = 3
    @State private var popover: Tool?

    /// Recordings can't be freeform, so that choice shows as Rectangle while recording is selected.
    private var shownMode: SnipMode { kind == .record && mode == .freeform ? .rect : mode }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { actions.newSnip(kind, shownMode, delay) } label: {
                    Label("New", systemImage: "plus")
                }
                .buttonStyle(FilledButtonStyle())
                .keyboardShortcut(doc.isEditingText ? nil : KeyboardShortcut("n"))
                .help(kind == .snip ? "New snip (⌘N)" : "New recording (⌘N)")

                HStack(spacing: 2) {
                    IconButton(icon: "camera", help: "Snip", selected: kind == .snip) { kind = .snip }
                    IconButton(icon: "video", help: "Record", selected: kind == .record) { kind = .record }
                }

                Menu {
                    ForEach(SnipMode.allCases.filter { kind == .snip || $0 != .freeform }) { m in
                        Button { mode = m } label: { Label(m.title, systemImage: m.icon) }
                    }
                } label: {
                    Image(systemName: shownMode.icon)
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
                .help("\(kind == .snip ? "Snipping" : "Recording") mode: \(shownMode.title)")

                if kind == .snip {
                    Menu {
                        ForEach([0, 3, 5, 10], id: \.self) { d in
                            Button(d == 0 ? "No delay" : "\(d) seconds") { delay = d }
                        }
                    } label: {
                        Label(delay == 0 ? "No delay" : "\(delay)s delay", systemImage: "timer")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .help("Snip after a delay")
                } else {
                    Menu {
                        ForEach(Prefs.recordDelayChoices, id: \.self) { d in
                            Button(d == 0 ? "Start right away" : "Start after \(d) seconds") { recordDelay = d }
                        }
                    } label: {
                        Label(recordDelay == 0 ? "Start right away" : "Start after \(recordDelay)s", systemImage: "timer")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .help("How long after you press Start the recording begins")
                }

                Spacer(minLength: 12)

                IconButton(icon: "arrow.uturn.backward", help: "Undo (⌘Z)") { doc.undo() }
                    .disabled(!doc.canUndo)
                    .keyboardShortcut(doc.isEditingText ? nil : KeyboardShortcut("z"))
                IconButton(icon: "arrow.uturn.forward", help: "Redo (⇧⌘Z)") { doc.redo() }
                    .disabled(!doc.canRedo)
                    .keyboardShortcut(doc.isEditingText ? nil : KeyboardShortcut("z", modifiers: [.command, .shift]))

                Divider().frame(height: 20).padding(.horizontal, 2)

                // Snips are already saved: show the file so it can be dragged anywhere (no copies).
                IconButton(icon: "folder", help: "Show in Finder (⌘S): it's already saved, drag it anywhere", label: "Show File", action: actions.showInFinder)
                    .keyboardShortcut(doc.isEditingText ? nil : KeyboardShortcut("s"))

                Button(action: actions.copy) {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(FilledButtonStyle())
                .keyboardShortcut(doc.isEditingText ? nil : KeyboardShortcut("c"))
                .help("Copy to clipboard (⌘C), then paste anywhere")

                IconButton(icon: "square.and.arrow.up", help: "Share", action: actions.share)
                    .background(AnchorView(box: actions.shareAnchor))

                Menu {
                    Button { actions.copyText() } label: { Label("Copy all text", systemImage: "text.viewfinder") }
                    Button { actions.save() } label: { Label("Save As…", systemImage: "square.and.arrow.down") }
                    Divider()
                    Button("Settings…") { SettingsWindow.show() }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            HStack(spacing: 4) {
                if doc.tool == .crop {
                    Text("Drag the corners to crop")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 8)
                    IconButton(icon: "arrow.counterclockwise", help: "Reset crop", label: "Reset") { doc.resetCrop() }
                    IconButton(icon: "xmark", help: "Cancel (Esc)", label: "Cancel") { doc.cancelCrop() }
                    Button { doc.finishCrop() } label: { Label("Done", systemImage: "checkmark") }
                        .buttonStyle(FilledButtonStyle())
                        .help("Apply crop (Return)")
                } else {
                    toolButton(.pen)
                    toolButton(.highlighter)
                    toolButton(.eraser)
                    toolButton(doc.lastShape, isShapeGroup: true)
                    toolButton(.text)
                    toolButton(.redact)
                    Divider().frame(height: 22).padding(.horizontal, 6)
                    toolButton(.crop)
                    Divider().frame(height: 22).padding(.horizontal, 6)
                    IconButton(icon: "text.viewfinder", help: "Text actions: copy all text in the snip", label: "Copy text", action: actions.copyText)
                }
            }
            .frame(height: 40)
            .padding(.bottom, 4)
        }
        .background(.bar)
    }

    private func toolButton(_ tool: Tool, isShapeGroup: Bool = false) -> some View {
        let selected = isShapeGroup ? doc.tool.isShape : doc.tool == tool
        let hasOptions = tool.hasStyle
        return Button {
            if selected && hasOptions {
                popover = isShapeGroup ? .arrow : tool
            } else {
                doc.select(tool)
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: tool.icon)
                    .font(.system(size: 16, weight: .medium))
                    .frame(height: 20)
                Capsule()
                    .fill(hasOptions ? Color(nsColor: doc.color(for: tool)) : Color.clear)
                    .frame(width: 18, height: 3)
            }
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .frame(width: 42, height: 34)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.18) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isShapeGroup ? "Shapes" + (selected ? " — click again for shape, color and size" : "")
              : tool.title + (hasOptions && selected ? " — click again for color and size" : ""))
        .popover(isPresented: Binding(
            get: { popover == (isShapeGroup ? .arrow : tool) },
            set: { if !$0 { popover = nil } }
        ), arrowEdge: .bottom) {
            StylePopover(doc: doc, tool: isShapeGroup ? doc.lastShape : tool, isShapeGroup: isShapeGroup)
        }
    }
}

private struct StylePopover: View {
    @ObservedObject var doc: EditorDocument
    let tool: Tool
    let isShapeGroup: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isShapeGroup {
                HStack(spacing: 4) {
                    ForEach(Tool.shapes) { shape in
                        IconButton(icon: shape.icon, help: shape.title, selected: doc.tool == shape) { doc.select(shape) }
                    }
                }
            }
            Text("Color").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(24), spacing: 8), count: 8), spacing: 8) {
                ForEach(palette.indices, id: \.self) { i in
                    let c = palette[i]
                    let selected = sameColor(c, doc.color(for: tool))
                    Circle()
                        .fill(Color(nsColor: c))
                        .frame(width: 22, height: 22)
                        .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 1))
                        .overlay(Circle().stroke(Color.accentColor, lineWidth: selected ? 2.5 : 0).padding(-3))
                        .contentShape(Circle())
                        .onTapGesture { doc.setColor(c, for: tool) }
                }
            }
            ColorPicker("More colors", selection: Binding(
                get: { Color(nsColor: doc.color(for: tool)) },
                set: { doc.setColor(NSColor($0), for: tool) }
            ), supportsOpacity: false)
            .font(.system(size: 12))

            Text(tool == .text ? "Text size" : "Size").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            HStack {
                Slider(value: Binding(
                    get: { doc.size(for: tool) },
                    set: { doc.setSize($0.rounded(), for: tool) }
                ), in: tool.sizeRange)
                Text("\(Int(doc.size(for: tool)))")
                    .font(.system(size: 12).monospacedDigit())
                    .frame(width: 28, alignment: .trailing)
            }
        }
        .padding(16)
        .frame(width: 290)
    }
}

private struct StatusHUD: View {
    @ObservedObject var doc: EditorDocument

    var body: some View {
        ZStack {
            if let status = doc.status {
                Text(status)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.78)))
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: doc.status)
        .frame(width: 360, height: 44)
    }
}
