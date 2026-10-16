import AppKit
import SwiftUI

/// Runs the snip and record flows: hides Snip's own windows, freezes the screen,
/// shows the overlay, then hands the result to the editor or the recorder.
@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    private var session: CaptureSession?
    private var starting = false
    private var hiddenWindows: [NSWindow] = []
    private var countdown: DelayCountdown?

    private(set) var recording: RecordingController? {
        didSet { onRecordingChanged?(recording != nil) }
    }
    var onRecordingChanged: ((Bool) -> Void)?

    func recordHotkey() {
        if let recording {
            recording.handleHotkey()
        } else {
            begin(.record)
        }
    }

    func begin(_ kind: CaptureKind, delay: Int = 0, after: TimeInterval = 0, mode: SnipMode? = nil) {
        guard recording == nil, session == nil, !starting, countdown == nil else { return }
        guard Permission.ensureScreenRecording() else { return }
        if let mode { Prefs.snipMode = mode }
        Toast.dismiss()
        hideAppWindows()

        if delay > 0 {
            countdown = DelayCountdown.show(seconds: delay) { [weak self] in
                self?.countdown = nil
                self?.capture(kind, after: 0.15)
            }
            return
        }
        capture(kind, after: max(after, hiddenWindows.isEmpty ? 0 : 0.2))
    }

    private func capture(_ kind: CaptureKind, after: TimeInterval) {
        starting = true
        Task {
            if after > 0 { try? await Task.sleep(for: .seconds(after)) }
            defer { starting = false }
            do {
                let shots = try await ScreenCapture.freezeDisplays()
                let windows = ScreenCapture.visibleWindows()
                let state = OverlayState(kind: kind, mode: Prefs.snipMode)
                let session = CaptureSession(state: state, shots: shots, windowInfos: windows) { [weak self] result in
                    self?.sessionEnded(result)
                }
                self.session = session
                session.present()
            } catch {
                restoreAppWindows()
                Permission.showAlert(error: error)
            }
        }
    }

    private func sessionEnded(_ result: CaptureResult?) {
        session = nil
        guard let result else {
            restoreAppWindows()
            return
        }
        Prefs.snipMode = result.mode
        switch result.kind {
        case .snip:
            guard let image = result.croppedImage() else { return restoreAppWindows() }
            // The new snip opens in the editor in place of the one that was open, rather than
            // bringing the old picture back next to it.
            let frame = Prefs.openEditor ? retireHiddenEditors() : nil
            restoreAppWindows()
            SnipOutput.deliver(image, scale: result.shot.scale, editorFrame: frame)
        case .record:
            recording = RecordingController(shot: result.shot, rect: result.boundingRect) { [weak self] in
                self?.recording = nil
                self?.restoreAppWindows()
            }
        }
    }

    private func hideAppWindows() {
        hiddenWindows = WindowTracker.windows.filter { $0.isVisible && !$0.isMiniaturized }
        for window in hiddenWindows { window.orderOut(nil) }
    }

    /// Closes the editors hidden for this capture and returns the last one's frame.
    private func retireHiddenEditors() -> NSRect? {
        var frame: NSRect?
        hiddenWindows.removeAll { window in
            guard let editor = EditorWindowController.controller(for: window) else { return false }
            frame = editor.retire()
            return true
        }
        return frame
    }

    private func restoreAppWindows() {
        for window in hiddenWindows { window.orderFront(nil) }
        hiddenWindows = []
    }
}

/// What happens right after a snip: copy it, save it, then show the corner preview (or the editor).
@MainActor
enum SnipOutput {
    static func deliver(_ image: CGImage, scale: CGFloat, editorFrame: NSRect? = nil) {
        if Prefs.autoCopy {
            Clipboard.copy(image, scale: scale)
        }
        let folder = Prefs.autoSave ? Prefs.snipFolder : FileNamer.tempFolder
        let url = FileNamer.url(in: folder, prefix: "Snip", ext: "png")
        var saved: URL?
        if let data = image.pngData(scale: scale), (try? data.write(to: url)) != nil {
            saved = url
        }
        if Prefs.openEditor {
            EditorWindowController.open(image: image, scale: scale, fileURL: Prefs.autoSave ? saved : nil, replacing: editorFrame)
        } else if Prefs.showToast {
            Toast.show(image: image, scale: scale, fileURL: saved, savedToFolder: Prefs.autoSave)
        }
    }
}

/// A small "Snipping in 3…" pill for delayed snips.
@MainActor
final class DelayCountdown: ObservableObject {
    @Published var remaining: Int
    private let panel: NSPanel
    private var task: Task<Void, Never>?

    static func show(seconds: Int, completion: @escaping () -> Void) -> DelayCountdown {
        let c = DelayCountdown(seconds: seconds)
        c.run(completion)
        return c
    }

    private init(seconds: Int) {
        remaining = seconds
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 56), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: DelayCountdownView(model: self))
        let frame = NSScreen.underMouse.visibleFrame
        panel.setFrameOrigin(CGPoint(x: frame.midX - 110, y: frame.maxY - 80))
    }

    private func run(_ completion: @escaping () -> Void) {
        panel.orderFrontRegardless()
        task = Task {
            while remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                remaining -= 1
            }
            panel.orderOut(nil)
            completion()
        }
    }
}

private struct DelayCountdownView: View {
    @ObservedObject var model: DelayCountdown
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "timer")
            Text("Snipping in \(model.remaining)…").monospacedDigit()
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Capsule().fill(Color.black.opacity(0.75)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
