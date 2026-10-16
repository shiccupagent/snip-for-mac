import AppKit
import AVFoundation
import AVKit
import Combine
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

/// Plays back a finished recording with Show File / Copy / Share / GIF buttons above and a timeline
/// editor below (trim, cut out parts, move speedrun splits; see `VideoTimelineView`).
@MainActor
final class VideoWindowController: NSWindowController, NSWindowDelegate {
    private static var openControllers: [VideoWindowController] = []

    private let model: VideoModel
    private let player: AVPlayer
    private let shareAnchor = AnchorBox()
    private var timerPanel: NSWindow?
    private let timeline = TimelineModel()
    private let playhead = PlayheadModel()
    private var timeObserver: Any?
    /// Scrubbing: at most one seek in flight, and the newest target waits for it (Apple's smooth
    /// scrubbing pattern), so dragging never queues up a backlog of frames to decode.
    private var seekTarget: Double?
    private var seeking = false
    private var playingWatch: AnyCancellable?

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

        let playerView = PlainPlayerView()
        playerView.player = player
        // The timeline below is the scrubber and play button.
        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspect

        let bar = NSHostingView(rootView: VideoBar(
            model: model,
            timeline: timeline,
            shareAnchor: shareAnchor,
            // Opens the bar in picture mode like every other New; its 🎥 button switches to recording.
            onNew: { CaptureCoordinator.shared.begin(.snip) },
            onCopy: { [weak self] in self?.copy() },
            onShare: { [weak self] in self?.share() },
            onGIF: { [weak self] in self?.makeGIF() },
            onEditTimer: { [weak self] in self?.editTimer() },
            onReveal: { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        ))

        let timelineView = NSHostingView(rootView: VideoTimelineHost(
            model: model,
            timeline: timeline,
            playhead: playhead,
            onSeek: { [weak self] t in self?.seek(t) },
            onPlayPause: { [weak self] in self?.playPause() },
            onMute: { [weak self] in self?.toggleMute() },
            onSave: { [weak self] in self?.saveEdit() }
        ))

        let container = NSView()
        for v in [playerView, bar, timelineView] as [NSView] {
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
            playerView.bottomAnchor.constraint(equalTo: timelineView.topAnchor),
            timelineView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            timelineView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            timelineView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.contentView = container

        let visible = NSScreen.underMouse.visibleFrame
        let width = min(max(pointSize.width, 700), visible.width * 0.85)
        let height = min(max(pointSize.height + 52 + 120, 520), visible.height * 0.85)
        window.minSize = NSSize(width: 680, height: 480)
        window.setContentSize(NSSize(width: width, height: height))
        window.center()

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        playingWatch = player.publisher(for: \.timeControlStatus).receive(on: RunLoop.main).sink { [weak self] status in
            MainActor.assumeIsolated { self?.playhead.playing = status != .paused }
        }
        Task { await loadTimeline() }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Development aid (`Snip dev-snapshot <video> <out.png> [--edit]`): draws this window to a PNG
    /// without ever showing it, optionally with a sample edit, so the timeline can be checked by eye.
    static func snapshot(url: URL, to out: URL, sampleEdit: Bool) async -> Bool {
        let controller = VideoWindowController(url: url, pointSize: CGSize(width: 1100, height: 520))
        guard let window = controller.window else { return false }
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(4))
        if sampleEdit {
            let d = controller.timeline.duration
            controller.timeline.trim(.start, at: d * 0.04)
            controller.timeline.split(at: d * 0.3)
            controller.timeline.split(at: d * 0.42)
            controller.timeline.selected = nil
            controller.timeline.removeSelected(or: d * 0.36)
            controller.timeline.selected = controller.timeline.edit.piece(at: d * 0.6)
            controller.playhead.time = d * 0.55
            controller.playhead.hover = d * 0.78
        }
        try? await Task.sleep(for: .milliseconds(600))
        defer { window.close() }
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: out)) != nil
    }

    /// Unsaved timeline edits: ask before closing.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard timeline.dirty, !model.busy else { return !model.busy }
        let alert = NSAlert()
        alert.messageText = "Save your edit to this recording?"
        alert.informativeText = "Your cuts and split changes aren't in the video yet."
        alert.addButton(withTitle: "Save Edit")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveEdit(closeAfter: true)
            return false
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        timerPanel?.close()
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        playingWatch = nil
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

    // MARK: Timeline

    /// Reads the file as it is now into the timeline: length, thumbnails and the speedrun log.
    private func loadTimeline() async {
        let asset = AVURLAsset(url: model.url)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let log = model.hasTimer ? try? RunLog.load(RunLog.url(for: model.url)) : nil
        timeline.load(duration: duration.isFinite ? duration : 0, log: log)
        timeline.setThumbnails([])
        guard duration.isFinite, duration > 0 else { return }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        let count = 30
        var images: [CGImage] = []
        for k in 0..<count {
            let time = CMTime(seconds: duration * (Double(k) + 0.5) / Double(count), preferredTimescale: 600)
            if let result = try? await generator.image(at: time) { images.append(result.image) }
        }
        timeline.setThumbnails(images)
    }

    private func seek(_ t: Double) {
        seekTarget = t
        if !seeking { seekToTarget() }
    }

    private func seekToTarget() {
        guard let t = seekTarget else { return }
        seekTarget = nil
        seeking = true
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                self?.seeking = false
                self?.seekToTarget()
            }
        }
    }

    private func toggleMute() {
        player.isMuted.toggle()
        playhead.muted = player.isMuted
    }

    private func playPause() {
        if player.timeControlStatus != .paused {
            player.pause()
            return
        }
        // Play from the first kept moment; at the end of the edit, start again from the top.
        let now = player.currentTime().seconds
        if let next = timeline.edit.keptTime(atOrAfter: now), timeline.edit.pieces.last.map({ next < $0.upperBound - 0.05 }) ?? false {
            if next > now + 0.01 { seek(next) }
        } else if let first = timeline.edit.pieces.first {
            seek(first.lowerBound)
        }
        player.play()
    }

    /// Follows playback with the playhead and jumps over cut-out parts, so the preview plays the edit.
    private func tick(_ t: Double) {
        // While scrubbing, the playhead follows the pointer, not the frames still being decoded.
        guard t.isFinite, !seeking, seekTarget == nil else { return }
        playhead.time = t
        guard player.timeControlStatus != .paused, timeline.edit.isCut else { return }
        if let next = timeline.edit.keptTime(atOrAfter: t) {
            if next > t + 0.03 { seek(next) }
        } else {
            player.pause()
        }
    }

    private func saveEdit(closeAfter: Bool = false) {
        guard !model.busy, timeline.dirty else { return }
        timerPanel?.close()
        let edit = timeline.edit
        let log = timeline.log
        model.busy = true
        model.status = "Saving the edit…"
        player.pause()
        Task {
            do {
                try await VideoCutter.save(edit, log: log, video: model.url) { [weak self] message in
                    self?.model.status = message
                }
                model.busy = false
                if closeAfter {
                    window?.close()
                    return
                }
                player.replaceCurrentItem(with: AVPlayerItem(url: model.url))
                await loadTimeline()
                flash(edit.isCut ? "Edit saved. The old version is in the Trash." : "Splits saved")
            } catch {
                model.busy = false
                flash("Couldn't save the edit: \(error.localizedDescription)")
            }
        }
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
                await loadTimeline()
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
    @ObservedObject var timeline: TimelineModel
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
                .disabled(timeline.dirty)
            IconButton(icon: "square.and.arrow.up", help: "Share", action: onShare)
                .background(AnchorView(box: shareAnchor))
                .disabled(timeline.dirty)
            IconButton(icon: "photo.on.rectangle", help: "Make a GIF and copy it", label: "GIF", action: onGIF)
                .disabled(model.busy || timeline.dirty)
            if model.hasTimer {
                IconButton(icon: "flag.checkered", help: "Edit the speedrun timer: game, split names and split times", label: "Edit Timer", action: onEditTimer)
                    .disabled(model.busy || timeline.dirty)
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

/// The timeline, greyed out while the file is being rewritten.
private struct VideoTimelineHost: View {
    @ObservedObject var model: VideoModel
    let timeline: TimelineModel
    let playhead: PlayheadModel
    let onSeek: (Double) -> Void
    let onPlayPause: () -> Void
    let onMute: () -> Void
    let onSave: () -> Void

    var body: some View {
        VideoTimelineView(model: timeline, playhead: playhead, busy: model.busy, onSeek: onSeek,
                          onPlayPause: onPlayPause, onMute: onMute, onSave: onSave)
    }
}

/// The video itself: no built-in controls (the timeline has them), and it never takes the keyboard,
/// so Space, Delete and ⌘B reach the timeline.
private final class PlainPlayerView: AVPlayerView {
    override var acceptsFirstResponder: Bool { false }
}
