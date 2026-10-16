import AppKit
import AVFoundation
import Combine
import ScreenCaptureKit
import SwiftUI

@MainActor
final class RecordState: ObservableObject {
    enum Phase: Equatable {
        case ready
        case countdown(Int)
        case recording
        case paused
        case saving
    }

    @Published var phase: Phase = .ready
    @Published var elapsed: TimeInterval = 0
    @Published var mic: Bool { didSet { Prefs.recordMic = mic } }
    @Published var systemAudio: Bool { didSet { Prefs.recordSystemAudio = systemAudio } }
    @Published var delay: Int { didSet { Prefs.recordDelay = delay } }
    @Published var speedrun: Bool { didSet { Prefs.speedrunTimer = speedrun } }

    /// The speedrun toggle sits next to the delay button and appears once a delay is set:
    /// the countdown is the run's "3, 2, 1, go".
    var showsSpeedrun: Bool { speedrun && delay > 0 }

    init() {
        mic = Prefs.recordMic
        systemAudio = Prefs.recordSystemAudio
        delay = Prefs.recordDelay
        speedrun = Prefs.speedrunTimer
    }

    /// Steps through Prefs.recordDelayChoices: now, 3 s, 5 s, 10 s.
    func cycleDelay() {
        let choices = Prefs.recordDelayChoices
        let i = choices.firstIndex(of: delay) ?? 0
        delay = choices[(i + 1) % choices.count]
    }
}

/// Runs one screen recording: the dashed region outline, the floating control bar
/// (Start · mic · sound · Cancel, then timer · Pause · Stop · Discard), and the countdown.
@MainActor
final class RecordingController {
    let shot: DisplayShot
    /// Display-local points, top-left origin.
    let rect: CGRect
    let state = RecordState()

    private let nsRegion: CGRect
    private let border: RegionBorderWindow
    private var bar: NSPanel!
    private let onFinish: () -> Void
    private var recorder: Recorder?
    private var countdownTask: Task<Void, Never>?
    private var timer: Timer?
    private var accumulated: TimeInterval = 0
    private var segmentStart: Date?
    private var finished = false
    private var stateWatch: AnyCancellable?

    init(shot: DisplayShot, rect: CGRect, onFinish: @escaping () -> Void) {
        let r = rect.integral.intersection(CGRect(origin: .zero, size: shot.screen.frame.size))
        self.shot = shot
        self.rect = r
        self.onFinish = onFinish
        let frame = shot.screen.frame
        nsRegion = CGRect(x: frame.minX + r.minX, y: frame.maxY - r.maxY, width: r.width, height: r.height)
        border = RegionBorderWindow(region: nsRegion)

        let view = RecordBarView(
            state: state,
            onStart: { [weak self] in self?.start() },
            onPause: { [weak self] in self?.togglePause() },
            onStop: { [weak self] in self?.stop() },
            onDiscard: { [weak self] in self?.discard() }
        )
        let panel = BarPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 64), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = FirstMouseHostingView(rootView: view)
        bar = panel

        border.orderFrontRegardless()
        positionBar()
        bar.orderFrontRegardless()

        stateWatch = state.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.syncSpeedrun()
                    self?.syncBarPlace()
                }
            }
        }
        syncSpeedrun()
    }

    private var barAtTop = false

    /// Once recording starts, the bar becomes a tab hanging from the top-centre of the screen.
    private func syncBarPlace() {
        let atTop: Bool
        switch state.phase {
        case .recording, .paused, .saving: atTop = true
        case .ready, .countdown: atTop = false
        }
        guard atTop != barAtTop else { return }
        barAtTop = atTop
        if atTop {
            let screen = shot.screen.frame
            let size = bar.frame.size
            bar.setFrameOrigin(CGPoint(x: screen.midX - size.width / 2, y: screen.maxY - size.height))
        } else {
            positionBar()
        }
    }

    /// Shows the speedrun timer in the corner of the recorded area while its toggle is on.
    private func syncSpeedrun() {
        let speedrun = SpeedrunController.shared
        if state.showsSpeedrun && !finished {
            if !speedrun.isShowing { speedrun.show(in: nsRegion, scale: shot.scale) }
        } else {
            speedrun.hide()
        }
    }

    private func positionBar() {
        let size = bar.frame.size
        let visible = shot.screen.visibleFrame
        var x = nsRegion.midX - size.width / 2
        var y = nsRegion.minY - size.height - 4
        if y < visible.minY { y = max(nsRegion.minY + 8, visible.minY + 8) }
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        bar.setFrameOrigin(CGPoint(x: x, y: y))
    }

    // MARK: Controls

    func handleHotkey() {
        switch state.phase {
        case .ready: start()
        case .recording, .paused: stop()
        case .countdown, .saving: break
        }
    }

    func stopOrCancel() {
        switch state.phase {
        case .ready, .countdown: discard()
        case .recording, .paused: stop()
        case .saving: break
        }
    }

    func start() {
        guard state.phase == .ready else { return }
        let seconds = state.delay
        countdownTask = Task {
            for n in stride(from: seconds, through: 1, by: -1) {
                state.phase = .countdown(n)
                border.countdown = n
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            border.countdown = nil
            await beginRecording()
        }
    }

    private func beginRecording() async {
        if state.mic {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        let url = FileNamer.url(in: Prefs.recordFolder, prefix: "Recording", ext: "mp4")
        let recorder = Recorder(url: url)
        // Draws the speedrun timer into the video, and keeps a copy without it so the timer can be
        // redrawn after the splits are fixed (`snip speedrun render`).
        recorder.overlay = SpeedrunController.shared.recordingOverlay
        if state.showsSpeedrun {
            recorder.cleanURL = url.deletingLastPathComponent()
                .appendingPathComponent(url.deletingPathExtension().lastPathComponent + " (no timer).mp4")
        }
        recorder.onStreamError = { [weak self] error in self?.fail(error) }
        do {
            let content = try await ScreenCapture.content()
            guard let display = content.displays.first(where: { $0.displayID == shot.display.displayID }) else {
                throw NSError(domain: "Snip", code: 3, userInfo: [NSLocalizedDescriptionKey: "That display is no longer connected."])
            }
            let me = ProcessInfo.processInfo.processIdentifier
            let ownApps = content.applications.filter { $0.processID == me }
            // Snip's own windows stay out of recordings (the speedrun timer is drawn in by the recorder).
            let filter: SCContentFilter
            if ownApps.isEmpty {
                let ownWindows = content.windows.filter { $0.owningApplication?.processID == me }
                filter = SCContentFilter(display: display, excludingWindows: ownWindows)
            } else {
                filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            }
            let options = Recorder.Options(systemAudio: state.systemAudio, microphone: state.mic, fps: Prefs.recordFPS)
            try await recorder.start(filter: filter, sourceRect: rect, pixelScale: shot.scale, options: options)
            self.recorder = recorder
            state.phase = .recording
            // The run starts with the recording, right as the countdown ends.
            if state.showsSpeedrun {
                SpeedrunController.shared.startLog { [weak recorder] in recorder?.videoTime() ?? 0 }
                if SpeedrunController.shared.timer.phase == .idle { SpeedrunController.shared.timer.split() }
            }
            segmentStart = Date()
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        } catch {
            fail(error)
        }
    }

    private func tick() {
        state.elapsed = accumulated + (segmentStart.map { Date().timeIntervalSince($0) } ?? 0)
    }

    func togglePause() {
        guard let recorder else { return }
        switch state.phase {
        case .recording:
            recorder.setPaused(true)
            accumulated += segmentStart.map { Date().timeIntervalSince($0) } ?? 0
            segmentStart = nil
            state.phase = .paused
            border.paused = true
        case .paused:
            recorder.setPaused(false)
            segmentStart = Date()
            state.phase = .recording
            border.paused = false
        default:
            break
        }
        tick()
    }

    func stop() {
        guard state.phase == .recording || state.phase == .paused, let recorder else { return }
        state.phase = .saving
        timer?.invalidate()
        let endTime = recorder.videoTime()
        Task {
            let url = await recorder.stop()
            if let url {
                SpeedrunController.shared.finishLog(video: url, clean: recorder.wroteClean ? recorder.cleanURL : nil,
                                                    endTime: endTime, pixelsPerPoint: recorder.pixelsPerPoint)
            } else {
                SpeedrunController.shared.cancelLog()
            }
            close()
            if let url {
                if Prefs.autoCopy { Clipboard.copyFile(url) }
                VideoWindowController.open(url: url, pointSize: rect.size)
            } else {
                showError("Nothing was recorded. Try again, and make sure something on screen changes.")
            }
            finish()
        }
    }

    func discard() {
        countdownTask?.cancel()
        timer?.invalidate()
        let recorder = self.recorder
        SpeedrunController.shared.cancelLog()
        Task {
            if let recorder, let url = await recorder.stop() {
                try? FileManager.default.removeItem(at: url)
            }
            if let clean = recorder?.cleanURL { try? FileManager.default.removeItem(at: clean) }
            close()
            finish()
        }
    }

    private func fail(_ error: Error) {
        guard !finished else { return }
        countdownTask?.cancel()
        timer?.invalidate()
        let recorder = self.recorder
        Task {
            let endTime = recorder?.videoTime() ?? 0
            if let recorder, let url = await recorder.stop() {
                SpeedrunController.shared.finishLog(video: url, clean: recorder.wroteClean ? recorder.cleanURL : nil,
                                                    endTime: endTime, pixelsPerPoint: recorder.pixelsPerPoint)
                VideoWindowController.open(url: url, pointSize: rect.size)
            } else {
                SpeedrunController.shared.cancelLog()
            }
            close()
            showError("Recording stopped: \(error.localizedDescription)")
            finish()
        }
    }

    private func close() {
        stateWatch = nil
        border.orderOut(nil)
        bar.orderOut(nil)
        SpeedrunController.shared.hide()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onFinish()
    }

    private func showError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Screen recording"
        alert.informativeText = message
        alert.runModal()
    }
}

final class BarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The dashed outline drawn just outside the recorded area. It belongs to Snip, so it isn't recorded.
final class RegionBorderWindow: NSWindow {
    private let borderView: RegionBorderView

    init(region: CGRect) {
        let pad: CGFloat = 4
        borderView = RegionBorderView(pad: pad)
        super.init(contentRect: region.insetBy(dx: -pad, dy: -pad), styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = borderView
    }

    var countdown: Int? {
        didSet { borderView.countdown = countdown; borderView.needsDisplay = true }
    }

    var paused = false {
        didSet { borderView.paused = paused; borderView.needsDisplay = true }
    }
}

private final class RegionBorderView: NSView {
    let pad: CGFloat
    var countdown: Int?
    var paused = false

    init(pad: CGFloat) {
        self.pad = pad
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let region = bounds.insetBy(dx: pad, dy: pad)
        if let n = countdown {
            NSColor.black.withAlphaComponent(0.35).setFill()
            region.fill()
            let text = "\(n)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: min(140, region.height * 0.5), weight: .bold),
                .foregroundColor: NSColor.white,
            ]
            let size = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: region.midX - size.width / 2, y: region.midY - size.height / 2), withAttributes: attrs)
        }
        let path = NSBezierPath(rect: bounds.insetBy(dx: pad - 2, dy: pad - 2))
        path.lineWidth = 2
        path.setLineDash([7, 4], count: 2, phase: 0)
        (paused ? NSColor.systemOrange : NSColor.systemRed).setStroke()
        path.stroke()
    }
}

private struct RecordBarView: View {
    @ObservedObject var state: RecordState
    @ObservedObject var speedrun = SpeedrunController.shared
    let onStart: () -> Void
    let onPause: () -> Void
    let onStop: () -> Void
    let onDiscard: () -> Void

    @State private var expanded = false
    @State private var hoverToken = 0

    /// While recording, the controls fold into a small tab at the top of the screen (out of the way);
    /// hovering it opens them.
    private var isRecordingPhase: Bool {
        switch state.phase {
        case .recording, .paused, .saving: return true
        case .ready, .countdown: return false
        }
    }

    var body: some View {
        if isRecordingPhase {
            recordingTab
        } else {
            controls
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(Capsule().stroke(Color.primary.opacity(0.12)))
                .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var recordingTab: some View {
        let open = expanded || state.phase == .saving
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: open ? 14 : 8, bottomTrailingRadius: open ? 14 : 8)
        return Group {
            if open {
                controls
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .padding(.bottom, 7)
                    .background(shape.fill(Color(nsColor: .windowBackgroundColor)))
                    .overlay(shape.stroke(Color.primary.opacity(0.12)))
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
            } else {
                HStack(spacing: 5) {
                    Circle()
                        .fill(state.phase == .paused ? Color.orange : Color.red)
                        .frame(width: 7, height: 7)
                    Text(timeString(state.elapsed))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 20)
                .background(shape.fill(Color.black.opacity(0.78)))
                .help("Recording. Point here for the controls")
            }
        }
        .onHover { inside in
            hoverToken += 1
            if inside {
                withAnimation(.easeOut(duration: 0.15)) { expanded = true }
            } else {
                let token = hoverToken
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(700))
                    if token == hoverToken { withAnimation(.easeIn(duration: 0.15)) { expanded = false } }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var controls: some View {
        HStack(spacing: 6) {
            switch state.phase {
            case .ready:
                Button(action: onStart) { Label("Start", systemImage: "record.circle") }
                    .buttonStyle(FilledButtonStyle(tint: .red))
                    .help("Start recording")
                if #available(macOS 15.0, *) {
                    IconButton(icon: state.mic ? "mic.fill" : "mic.slash", help: state.mic ? "Microphone on" : "Microphone off", selected: state.mic) {
                        state.mic.toggle()
                    }
                }
                IconButton(icon: state.systemAudio ? "speaker.wave.2.fill" : "speaker.slash", help: state.systemAudio ? "Computer sound on" : "Computer sound off", selected: state.systemAudio) {
                    state.systemAudio.toggle()
                }
                delayButton
                if state.delay > 0 {
                    IconButton(
                        icon: "flag.checkered",
                        help: state.speedrun ? "Speedrun timer on: it shows in the corner and starts with the recording" : "Add a speedrun timer to the recording",
                        label: "Splits",
                        selected: state.speedrun
                    ) {
                        state.speedrun.toggle()
                    }
                    if state.speedrun {
                        visibilityButton
                        IconButton(icon: "pencil", help: "Edit the game, category and split names") {
                            SplitsEditorWindow.show()
                        }
                    }
                }
                Divider().frame(height: 20)
                IconButton(icon: "xmark", help: "Cancel", action: onDiscard)
            case .countdown(let n):
                Text("Recording in \(n)…")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 6)
                IconButton(icon: "xmark", help: "Cancel", action: onDiscard)
            case .recording, .paused:
                Circle()
                    .fill(state.phase == .paused ? Color.orange : Color.red)
                    .frame(width: 9, height: 9)
                Text(timeString(state.elapsed))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .frame(minWidth: 48, alignment: .leading)
                IconButton(icon: state.phase == .paused ? "play.fill" : "pause.fill", help: state.phase == .paused ? "Resume" : "Pause", action: onPause)
                Button(action: onStop) { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(FilledButtonStyle(tint: .red))
                    .help("Stop and save")
                IconButton(icon: "trash", help: "Discard recording", action: onDiscard)
                if state.showsSpeedrun { visibilityButton }
            case .saving:
                ProgressView().controlSize(.small)
                Text("Saving…").font(.system(size: 13, weight: .medium))
            }
        }
    }

    /// Shows or hides the speedrun timer on screen; it's in the recording either way.
    private var visibilityButton: some View {
        IconButton(
            icon: speedrun.onScreen ? "eye" : "eye.slash",
            help: speedrun.onScreen ? "Timer shown on screen (and recorded). Click to hide it while you play" : "Timer hidden on screen, still recorded. Click to show it",
            selected: speedrun.onScreen
        ) {
            speedrun.toggleOnScreen()
        }
    }

    private var delayButton: some View {
        IconButton(
            icon: "timer",
            help: state.delay == 0 ? "Starts as soon as you press Start. Click for a delay" : "Starts \(state.delay) seconds after you press Start. Click to change",
            label: state.delay == 0 ? "Now" : "\(state.delay)s",
            selected: state.delay > 0
        ) {
            state.cycleDelay()
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
