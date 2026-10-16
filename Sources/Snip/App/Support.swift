import AppKit
import SwiftUI

extension CGContext {
    /// Draws an image right side up in a context whose y axis points down.
    func drawUpright(_ image: CGImage, in rect: CGRect) {
        saveGState()
        translateBy(x: 0, y: rect.maxY)
        scaleBy(x: 1, y: -1)
        draw(image, in: CGRect(x: rect.minX, y: 0, width: rect.width, height: rect.height))
        restoreGState()
    }
}

extension CGImage {
    var pixelSize: CGSize { CGSize(width: width, height: height) }

    /// PNG data tagged with the right DPI so a Retina snip pastes at its on-screen size.
    func pngData(scale: CGFloat) -> Data? {
        bitmapRep(scale: scale).representation(using: .png, properties: [:])
    }

    func jpegData(scale: CGFloat) -> Data? {
        bitmapRep(scale: scale).representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }

    func bitmapRep(scale: CGFloat) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(cgImage: self)
        rep.size = NSSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        return rep
    }

    func nsImage(scale: CGFloat) -> NSImage {
        NSImage(cgImage: self, size: NSSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale))
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static var underMouse: NSScreen {
        let p = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(p, $0.frame, false) } ?? main ?? screens[0]
    }
}

/// A hosting view that reacts to the first click even when its window isn't key.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A hosting view that never takes mouse events, for overlays like status messages.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Holds the NSView behind a SwiftUI button so AppKit popups (like the share sheet) can anchor to it.
final class AnchorBox {
    weak var view: NSView?
}

struct AnchorView: NSViewRepresentable {
    let box: AnchorBox
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        box.view = v
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        box.view = nsView
    }
}

enum FileNamer {
    static var tempFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Snip", isDirectory: true)
    }

    static func url(in folder: URL, prefix: String, ext: String) -> URL {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = "\(prefix) \(f.string(from: Date()))"
        var url = folder.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        return url
    }
}

enum Clipboard {
    static func copy(_ image: CGImage, scale: CGFloat) {
        let rep = image.bitmapRep(scale: scale)
        let pb = NSPasteboard.general
        pb.clearContents()
        if let png = rep.representation(using: .png, properties: [:]) {
            pb.setData(png, forType: .png)
        }
        if let tiff = rep.tiffRepresentation {
            pb.setData(tiff, forType: .tiff)
        }
    }

    /// Puts a file on the clipboard, so pasting into Messages, Slack, Mail or Finder attaches it.
    static func copyFile(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
    }

    static func copyText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

@MainActor
enum Permission {
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    nonisolated static var screenRecordingAllowed: Bool { CGPreflightScreenCaptureAccess() }

    /// Returns true when capture can go ahead; otherwise asks the user for permission.
    static func ensureScreenRecording() -> Bool {
        if screenRecordingAllowed { return true }
        let askedKey = "askedScreenPermission"
        if !UserDefaults.standard.bool(forKey: askedKey) {
            UserDefaults.standard.set(true, forKey: askedKey)
            if CGRequestScreenCaptureAccess() { return true }
            return false
        }
        showAlert()
        return false
    }

    static func request() {
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(settingsURL)
        }
    }

    static func showAlert(error: Error? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Snip needs permission to see your screen"
        var info = "Open System Settings → Privacy & Security → Screen & System Audio Recording, turn on Snip, then reopen Snip.\n\nIf Snip is already on, turn it off and on again. macOS sometimes keeps an old entry after an update."
        if let error { info += "\n\n(\(error.localizedDescription))" }
        alert.informativeText = info
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Reopen Snip")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: NSWorkspace.shared.open(settingsURL)
        case .alertSecondButtonReturn: relaunch()
        default: break
        }
    }

    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.8; /usr/bin/open \"\(Bundle.main.bundlePath)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}

// MARK: Shared button styles (modelled on Snipping Tool's toolbar)

struct FilledButtonStyle: ButtonStyle {
    var tint: Color = .accentColor
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(tint.opacity(configuration.isPressed ? 0.75 : 1)))
            .contentShape(Rectangle())
    }
}

struct IconButton: View {
    let icon: String
    let help: String
    var label: String? = nil
    var selected = false
    let action: () -> Void

    @State private var hover = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 14, weight: .medium))
                if let label { Text(label).font(.system(size: 12.5)) }
            }
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .padding(.horizontal, label == nil ? 7 : 9)
            .frame(minWidth: 30, minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(hover ? 0.08 : 0))
            )
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}
