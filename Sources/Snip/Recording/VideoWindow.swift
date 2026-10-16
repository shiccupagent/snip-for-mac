import AppKit
import AVFoundation
import AVKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class VideoModel: ObservableObject {
    let url: URL
    @Published var status: String?
    @Published var busy = false
    /// The recording has a speedrun timer that can be edited and redrawn.
    let hasTimer: Bool
    init(url: URL) {
        self.url = url
        hasTimer = FileManager.default.fileExists(atPath: RunLog.url(for: url).path)
    }
}

/// Plays back a finished recording with big Copy / Save / Share / GIF buttons underneath.
@MainActor
final class VideoWindowController: NSWindowController, NSWindowDelegate {
    private static var openControllers: [VideoWindowController] = []

    private let model: VideoModel
    private let player: AVPlayer
    private let shareAnchor = AnchorBox()
    private var timerPanel: NSWindow?

    static func open(url: URL, pointSize: CGSize) {
        let controller = VideoWindowController(url: url, pointSize: pointSize)
        openControllers.append(controller)
        guard let window = controller.window else { return }
        WindowTracker.track(window)
        window.makeKeyAndOrderFront(nil)
        controller.player.play()
    }

    init(url: URL, pointSize: CGSize) {
        model = VideoModel(url: url)
        player = AVPlayer(url: url)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        super.init(window: window)
        window.title = url.deletingPathExtension().lastPathComponent
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 680, height: 380)

        let playerView = AVPlayerView()
        playerView.player = player
        playerView.controlsStyle = .inline
        playerView.videoGravity = .resizeAspect

        let bar = NSHostingView(rootView: VideoBar(
            model: model,
            shareAnchor: shareAnchor,
            // Opens the bar in picture mode like every other New; its 🎥 button switches to recording.
            onNew: { CaptureCoordinator.shared.begin(.snip) },
            onCopy: { [weak self] in self?.copy() },
            onShare: { [weak self] in self?.share() },
            onGIF: { [weak self] in self?.makeGIF() },
            onEditTimer: { [weak self] in self?.editTimer() },
            onReveal: { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        ))

        let container = NSView()
        for v in [playerView, bar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            playerView.topAnchor.constraint(equalTo: bar.bottomAnchor),
            playerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.contentView = container

        let visible = NSScreen.underMouse.visibleFrame
        let width = min(max(pointSize.width, 700), visible.width * 0.85)
        let height = min(max(pointSize.height + 52, 420), visible.height * 0.85)
        window.setContentSize(NSSize(width: width, height: height))
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        timerPanel?.close()
        player.pause()
        VideoWindowController.openControllers.removeAll { $0 === self }
    }

    private func flash(_ message: String) {
        model.status = message
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if model.status == message { model.status = nil }
        }
    }

    private func copy() {
        Clipboard.copyFile(model.url)
        flash("Copied — paste it into any chat or email")
    }

    private func share() {
        guard let anchor = shareAnchor.view else { return }
        NSSharingServicePicker(items: [model.url]).show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    // MARK: Speedrun timer

    /// Opens the timer editor beside the video, so the video can still be scrubbed to find split moments.
    private func editTimer() {
        if let timerPanel, timerPanel.isVisible {
            timerPanel.makeKeyAndOrderFront(nil)
            return
        }
        let logURL = RunLog.url(for: model.url)
        let log: RunLog
        do {
            log = try RunLog.load(logURL)
        } catch {
            flash("Couldn't read the timer: \(error.localizedDescription)")
            return
        }
        let view = TimerEditView(
            log: log,
            now: { [weak self] in self?.player.currentTime().seconds ?? 0 },
            seek: { [weak self] t in
                self?.player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            },
            onApply: { [weak self] edited in self?.applyTimer(edited, logURL: logURL) },
            onCancel: { [weak self] in self?.timerPanel?.close() }
        )
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 460),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered, defer: false
        )
        panel.title = "Edit Timer"
        panel.contentViewController = NSHostingController(rootView: view)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        if let frame = window?.frame {
            let visible = window?.screen?.visibleFrame ?? frame
            let x = min(frame.maxX + 8, visible.maxX - panel.frame.width)
            panel.setFrameTopLeftPoint(NSPoint(x: x, y: frame.maxY))
        }
        timerPanel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    private func applyTimer(_ log: RunLog, logURL: URL) {
        guard !model.busy else { return }
        timerPanel?.close()
        model.busy = true
        model.status = "Redrawing the timer…"
        let at = player.currentTime()
        player.pause()
        Task {
            do {
                try log.data().write(to: logURL, options: .atomic)
                try await SpeedrunRenderer.rerender(logURL: logURL, to: model.url) { [weak self] fraction in
                    self?.model.status = "Redrawing the timer… \(Int(fraction * 100))%"
                }
                player.replaceCurrentItem(with: AVPlayerItem(url: model.url))
                await player.seek(to: at, toleranceBefore: .zero, toleranceAfter: .zero)
                model.busy = false
                flash("Timer updated")
            } catch {
                model.busy = false
                flash("Couldn't redraw the timer: \(error.localizedDescription)")
            }
        }
    }

    private func makeGIF() {
        guard !model.busy else { return }
        model.busy = true
        model.status = "Making GIF…"
        let source = model.url
        let dest = source.deletingPathExtension().appendingPathExtension("gif")
        Task {
            do {
                try await GIFExporter.export(from: source, to: dest) { [weak self] progress in
                    Task { @MainActor in self?.model.status = "Making GIF… \(Int(progress * 100))%" }
                }
                Clipboard.copyFile(dest)
                model.busy = false
                flash("GIF saved and copied — paste it anywhere")
                NSWorkspace.shared.activateFileViewerSelecting([dest])
            } catch {
                model.busy = false
                flash("Couldn't make GIF: \(error.localizedDescription)")
            }
        }
    }
}

private struct VideoBar: View {
    @ObservedObject var model: VideoModel
    let shareAnchor: AnchorBox
    let onNew: () -> Void
    let onCopy: () -> Void
    let onShare: () -> Void
    let onGIF: () -> Void
    let onEditTimer: () -> Void
    let onReveal: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onNew) { Label("New", systemImage: "plus") }
                .buttonStyle(FilledButtonStyle())
                .help("New snip or recording")
            if let status = model.status {
                Text(status)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
            }
            Spacer(minLength: 12)
            // Recordings are already saved: show the file so it can be dragged anywhere (no copies).
            IconButton(icon: "folder", help: "Show in Finder (⌘S): it's already saved, drag it anywhere", label: "Show File", action: onReveal)
                .keyboardShortcut("s")
            Button(action: onCopy) { Label("Copy", systemImage: "doc.on.doc") }
                .buttonStyle(FilledButtonStyle())
                .keyboardShortcut("c")
                .help("Copy the video (⌘C), then paste it into any app")
            IconButton(icon: "square.and.arrow.up", help: "Share", action: onShare)
                .background(AnchorView(box: shareAnchor))
            IconButton(icon: "photo.on.rectangle", help: "Make a GIF and copy it", label: "GIF", action: onGIF)
                .disabled(model.busy)
            if model.hasTimer {
                IconButton(icon: "flag.checkered", help: "Edit the speedrun timer: game, split names and split times", label: "Edit Timer", action: onEditTimer)
                    .disabled(model.busy)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

enum GIFExporter {
    static func export(from source: URL, to dest: URL, fps: Double = 12, maxWidth: CGFloat = 720,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw NSError(domain: "Snip", code: 4, userInfo: [NSLocalizedDescriptionKey: "The recording is empty."])
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxWidth, height: maxWidth * 4)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)

        let count = max(1, Int(duration * fps))
        try? FileManager.default.removeItem(at: dest)
        guard let destination = CGImageDestinationCreateWithURL(dest as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw NSError(domain: "Snip", code: 5, userInfo: [NSLocalizedDescriptionKey: "Couldn't create the GIF file."])
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0],
        ] as CFDictionary)
        let frameProperties = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFDelayTime as String: 1 / fps,
                kCGImagePropertyGIFUnclampedDelayTime as String: 1 / fps,
            ],
        ] as CFDictionary

        for i in 0..<count {
            let time = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
            let (image, _) = try await generator.image(at: time)
            CGImageDestinationAddImage(destination, image, frameProperties)
            progress(Double(i + 1) / Double(count))
        }
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "Snip", code: 6, userInfo: [NSLocalizedDescriptionKey: "Couldn't finish the GIF."])
        }
    }
}
