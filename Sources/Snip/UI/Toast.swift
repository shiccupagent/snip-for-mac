import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The "Snip copied to clipboard" preview that slides in at the bottom-right, like Windows' notification.
@MainActor
final class Toast {
    private static var current: Toast?

    private let panel: ToastPanel
    private let image: CGImage
    private let scale: CGFloat
    private let fileURL: URL?
    private var dismissTask: Task<Void, Never>?

    static func show(image: CGImage, scale: CGFloat, fileURL: URL?, savedToFolder: Bool) {
        current?.close(animated: false)
        let toast = Toast(image: image, scale: scale, fileURL: fileURL, savedToFolder: savedToFolder)
        current = toast
        toast.present()
    }

    static func dismiss() {
        current?.close(animated: false)
    }

    private init(image: CGImage, scale: CGFloat, fileURL: URL?, savedToFolder: Bool) {
        self.image = image
        self.scale = scale
        self.fileURL = fileURL
        panel = ToastPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 110), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let view = ToastView(
            image: image.nsImage(scale: scale),
            fileURL: fileURL,
            copiedAlready: Prefs.autoCopy,
            savedToFolder: savedToFolder,
            onOpen: { [weak self] in self?.openEditor() },
            onCopy: { [weak self] in self?.copy() },
            onSave: { [weak self] in self?.saveAs() },
            onClose: { [weak self] in self?.close(animated: true) },
            onHover: { [weak self] hovering in self?.hoverChanged(hovering) }
        )
        let host = FirstMouseHostingView(rootView: view)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        panel.setContentSize(size)
        panel.contentView = host
    }

    private func present() {
        let visible = NSScreen.underMouse.visibleFrame
        let size = panel.frame.size
        let end = CGPoint(x: visible.maxX - size.width - 8, y: visible.minY + 8)
        panel.setFrameOrigin(CGPoint(x: end.x + 24, y: end.y))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(end)
        }
        scheduleDismiss()
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task {
            try? await Task.sleep(for: .seconds(7))
            if !Task.isCancelled { close(animated: true) }
        }
    }

    private func hoverChanged(_ hovering: Bool) {
        if hovering { dismissTask?.cancel() } else { scheduleDismiss() }
    }

    private func openEditor() {
        close(animated: false)
        EditorWindowController.open(image: image, scale: scale, fileURL: Prefs.autoSave ? fileURL : nil)
    }

    private func copy() {
        Clipboard.copy(image, scale: scale)
    }

    private func saveAs() {
        dismissTask?.cancel()
        NSApp.activate(ignoringOtherApps: true)
        let save = NSSavePanel()
        save.allowedContentTypes = [.png, .jpeg]
        save.nameFieldStringValue = fileURL?.lastPathComponent ?? "Snip.png"
        save.directoryURL = Prefs.snipFolder
        if save.runModal() == .OK, let url = save.url {
            let data = url.pathExtension.lowercased().hasPrefix("jp") ? image.jpegData(scale: scale) : image.pngData(scale: scale)
            try? data?.write(to: url)
        }
        close(animated: true)
    }

    func close(animated: Bool) {
        dismissTask?.cancel()
        if Toast.current === self { Toast.current = nil }
        let panel = self.panel
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
            })
        } else {
            panel.orderOut(nil)
        }
    }
}

final class ToastPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct ToastView: View {
    let image: NSImage
    let fileURL: URL?
    let copiedAlready: Bool
    let savedToFolder: Bool
    let onOpen: () -> Void
    let onCopy: () -> Void
    let onSave: () -> Void
    let onClose: () -> Void
    let onHover: (Bool) -> Void

    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                Text(copiedAlready || copied ? "Snip copied to clipboard" : "Snip saved")
                    .font(.system(size: 13, weight: .semibold))
                Text("Click to mark up and share")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Button { onCopy(); copied = true } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(FilledButtonStyle())
                    IconButton(icon: "square.and.arrow.down", help: "Save as…", label: "Save", action: onSave)
                }
                .padding(.top, 5)
            }
            Spacer(minLength: 0)
            IconButton(icon: "xmark", help: "Dismiss", action: onClose)
                .opacity(hovering ? 1 : 0.5)
        }
        .padding(12)
        .frame(width: 380)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 4)
        .padding(12)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { h in
            hovering = h
            onHover(h)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        let img = Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: 110, maxHeight: 74)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
            .help("Drag into any app")
        if let fileURL {
            img.onDrag { NSItemProvider(contentsOf: fileURL) ?? NSItemProvider() }
        } else {
            img
        }
    }
}
