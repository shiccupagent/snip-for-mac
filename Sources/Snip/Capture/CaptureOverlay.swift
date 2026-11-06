import AppKit
import os

let captureLog = Logger(subsystem: "com.shiccup.snip", category: "capture")
import Combine
import SwiftUI

enum CaptureKind { case snip, record }

enum SnipMode: String, CaseIterable, Identifiable {
    case rect, freeform, window, fullscreen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rect: "Rectangle"
        case .freeform: "Freeform"
        case .window: "Window"
        case .fullscreen: "Full screen"
        }
    }

    var icon: String {
        switch self {
        case .rect: "rectangle.dashed"
        case .freeform: "lasso"
        case .window: "macwindow"
        case .fullscreen: "display"
        }
    }
}

enum CaptureRegion {
    case rect(CGRect)
    case freeform(CGPath)
}

struct CaptureResult {
    let kind: CaptureKind
    let mode: SnipMode
    let shot: DisplayShot
    let region: CaptureRegion

    func croppedImage() -> CGImage? {
        switch region {
        case .rect(let r): ScreenCapture.crop(shot, rect: r)
        case .freeform(let p): ScreenCapture.cropFreeform(shot, path: p)
        }
    }

    var boundingRect: CGRect {
        switch region {
        case .rect(let r): r
        case .freeform(let p): p.boundingBoxOfPath
        }
    }
}

@MainActor
final class OverlayState: ObservableObject {
    @Published var kind: CaptureKind {
        didSet { if kind == .record && mode == .freeform { mode = .rect } }
    }
    @Published var mode: SnipMode

    init(kind: CaptureKind, mode: SnipMode) {
        self.kind = kind
        self.mode = (kind == .record && mode == .freeform) ? .rect : mode
    }
}

/// The dimmed full-screen layer you drag across to pick what to snip or record.
@MainActor
final class CaptureSession {
    let state: OverlayState
    let shots: [DisplayShot]
    let windowInfos: [WindowInfo]
    private var windows: [OverlayWindow] = []
    private var views: [OverlayView] = []
    private var cancellable: AnyCancellable?
    private let completion: (CaptureResult?) -> Void
    private let onDelay: (Int) -> Void
    private var done = false

    /// `onDelay(seconds)`: the delay button was used; snip again once that many seconds have passed.
    init(state: OverlayState, shots: [DisplayShot], windowInfos: [WindowInfo],
         onDelay: @escaping (Int) -> Void, completion: @escaping (CaptureResult?) -> Void) {
        self.state = state
        self.shots = shots
        self.windowInfos = windowInfos
        self.onDelay = onDelay
        self.completion = completion
    }

    func present() {
        captureLog.notice("overlay shown, kind \(String(describing: self.state.kind), privacy: .public)")
        let mouse = NSEvent.mouseLocation
        for shot in shots {
            let window = OverlayWindow(screen: shot.screen)
            let view = OverlayView(shot: shot, session: self)
            view.frame = NSRect(origin: .zero, size: shot.screen.frame.size)
            window.contentView = view
            windows.append(window)
            views.append(view)
        }
        let keyIndex = shots.firstIndex { NSMouseInRect(mouse, $0.screen.frame, false) } ?? 0

        let bar = FirstMouseHostingView(rootView: CaptureBar(
            state: state,
            onDelay: { [weak self] seconds in self?.delay(seconds) },
            onClose: { [weak self] in self?.cancel("close button") }
        ))
        let host = views[keyIndex]
        let top = max(shots[keyIndex].screen.safeAreaInsets.top, 24)
        // Centred by constraints, so the bar stays centred as the delay choices open beside the timer.
        bar.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            bar.topAnchor.constraint(equalTo: host.topAnchor, constant: top),
        ])

        cancellable = state.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.views.forEach { $0.modeChanged() } }
        }

        NSApp.activate(ignoringOtherApps: true)
        for window in windows { window.orderFrontRegardless() }
        windows[keyIndex].makeKey()
        windows[keyIndex].makeFirstResponder(views[keyIndex])
        NSCursor.crosshair.set()
    }

    func clearHover(except view: OverlayView) {
        for v in views where v !== view { v.clearHover() }
    }

    func finish(_ region: CaptureRegion, on shot: DisplayShot) {
        captureLog.notice("overlay finished")
        guard !done else { return }
        done = true
        let result = CaptureResult(kind: state.kind, mode: state.mode, shot: shot, region: region)
        teardown()
        completion(result)
    }

    /// Closes the overlay so the screen can change (open a menu, hover a tooltip) before snipping again.
    func delay(_ seconds: Int) {
        captureLog.notice("overlay closed for a \(seconds) s delay")
        guard !done else { return }
        done = true
        teardown()
        onDelay(seconds)
    }

    func cancel(_ reason: String = "unknown") {
        captureLog.notice("overlay cancelled: \(reason, privacy: .public)")
        guard !done else { return }
        done = true
        teardown()
        completion(nil)
    }

    private func teardown() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
        cancellable = nil
        NSCursor.arrow.set()
    }
}

final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class OverlayView: NSView {
    let shot: DisplayShot
    unowned let session: CaptureSession

    private var dragStart: CGPoint?
    private var dragRect: CGRect?
    private var lasso: [CGPoint] = []
    private var hoverRect: CGRect?
    private var tracking: NSTrackingArea?

    init(shot: DisplayShot, session: CaptureSession) {
        self.shot = shot
        self.session = session
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var mode: SnipMode { session.state.mode }
    private var kind: CaptureKind { session.state.kind }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    func modeChanged() {
        dragRect = nil
        dragStart = nil
        lasso = []
        updateHover(at: mouseInView)
        needsDisplay = true
    }

    func clearHover() {
        guard hoverRect != nil else { return }
        hoverRect = nil
        needsDisplay = true
    }

    private var mouseInView: CGPoint? {
        guard let window else { return nil }
        let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(p) ? p : nil
    }

    private func updateHover(at p: CGPoint?) {
        guard let p else { hoverRect = nil; return }
        switch mode {
        case .window:
            let global = CGPoint(x: p.x + shot.cgFrame.minX, y: p.y + shot.cgFrame.minY)
            hoverRect = session.windowInfos.first { $0.cgFrame.contains(global) }.map {
                $0.cgFrame.offsetBy(dx: -shot.cgFrame.minX, dy: -shot.cgFrame.minY).intersection(bounds)
            }
        case .fullscreen:
            hoverRect = bounds
        default:
            hoverRect = nil
        }
    }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) {
        session.clearHover(except: self)
        updateHover(at: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        clearHover()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch mode {
        case .rect:
            dragStart = p
            dragRect = CGRect(origin: p, size: .zero)
        case .freeform:
            lasso = [p]
        case .window, .fullscreen:
            break
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch mode {
        case .rect:
            guard let start = dragStart else { return }
            let clamped = CGPoint(x: min(max(p.x, 0), bounds.maxX), y: min(max(p.y, 0), bounds.maxY))
            dragRect = CGRect(
                x: min(start.x, clamped.x), y: min(start.y, clamped.y),
                width: abs(clamped.x - start.x), height: abs(clamped.y - start.y)
            )
        case .freeform:
            if let last = lasso.last, hypot(p.x - last.x, p.y - last.y) > 1 { lasso.append(p) }
        default:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch mode {
        case .rect:
            if let r = dragRect, r.width >= 3, r.height >= 3 {
                session.finish(.rect(r), on: shot)
            } else {
                dragRect = nil
            }
        case .freeform:
            if lasso.count > 3, let path = lassoPath(), path.boundingBoxOfPath.width >= 3, path.boundingBoxOfPath.height >= 3 {
                session.finish(.freeform(path), on: shot)
            } else {
                lasso = []
            }
        case .window:
            updateHover(at: convert(event.locationInWindow, from: nil))
            if let r = hoverRect, !r.isEmpty { session.finish(.rect(r), on: shot) }
        case .fullscreen:
            session.finish(.rect(bounds), on: shot)
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        captureLog.notice("overlay key \(event.keyCode) mods \(event.modifierFlags.rawValue)")
        if event.keyCode == 53 { // Escape
            session.cancel("escape key")
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        session.cancel("cancelOperation from \(String(describing: NSApp.currentEvent))")
    }

    // MARK: Drawing

    private func lassoPath() -> CGPath? {
        guard lasso.count > 1 else { return nil }
        let path = CGMutablePath()
        path.addLines(between: lasso)
        path.closeSubpath()
        return path
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        if kind == .snip {
            ctx.drawUpright(shot.image, in: bounds)
        } else {
            ctx.clear(bounds)
        }

        var hole: CGPath?
        switch mode {
        case .rect: hole = dragRect.map { CGPath(rect: $0, transform: nil) }
        case .freeform: hole = lassoPath()
        case .window, .fullscreen: hole = hoverRect.map { CGPath(rect: $0, transform: nil) }
        }

        let dim = CGMutablePath()
        dim.addRect(bounds)
        if let hole { dim.addPath(hole) }
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.42).cgColor)
        ctx.addPath(dim)
        ctx.fillPath(using: .evenOdd)

        if let hole {
            let highlight = mode == .window || mode == .fullscreen
            ctx.addPath(hole)
            ctx.setLineWidth(highlight ? 3 : 1.5)
            ctx.setStrokeColor((highlight ? NSColor.controlAccentColor : NSColor.white).cgColor)
            ctx.strokePath()
        }

        if mode == .rect, let r = dragRect, r.width > 1, r.height > 1 {
            drawSizeLabel(for: r)
        }
    }

    private func drawSizeLabel(for r: CGRect) {
        let s = shot.scale
        let text = "\(Int((r.width * s).rounded())) × \(Int((r.height * s).rounded()))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attrs)
        var box = CGRect(x: r.maxX - size.width - 12, y: r.maxY + 6, width: size.width + 12, height: size.height + 6)
        if box.maxY > bounds.maxY { box.origin.y = r.maxY - box.height - 6 }
        if box.minX < bounds.minX { box.origin.x = r.minX }
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        text.draw(at: CGPoint(x: box.minX + 6, y: box.minY + 3), withAttributes: attrs)
    }
}

/// The bar at the top of the screen while snipping, laid out like Snipping Tool's:
/// snip/record toggle, then Rectangle · Freeform · Window · Full screen, the delay, then close.
struct CaptureBar: View {
    @ObservedObject var state: OverlayState
    let onDelay: (Int) -> Void
    let onClose: () -> Void

    @State private var choosingDelay: Bool
    @AppStorage(Prefs.Key.recordDelay) private var recordDelay = 3

    init(state: OverlayState, choosingDelay: Bool = false, onDelay: @escaping (Int) -> Void, onClose: @escaping () -> Void) {
        self.state = state
        _choosingDelay = State(initialValue: choosingDelay)
        self.onDelay = onDelay
        self.onClose = onClose
    }

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 2) {
                IconButton(icon: "camera", help: "Snip", selected: state.kind == .snip) { state.kind = .snip }
                IconButton(icon: "video", help: "Record", selected: state.kind == .record) { state.kind = .record }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))

            Divider().frame(height: 22).padding(.horizontal, 4)

            ForEach(SnipMode.allCases) { mode in
                IconButton(icon: mode.icon, help: mode.title, selected: state.mode == mode) { state.mode = mode }
                    .disabled(state.kind == .record && mode == .freeform)
            }

            Divider().frame(height: 22).padding(.horizontal, 4)

            delay

            Divider().frame(height: 22).padding(.horizontal, 4)

            IconButton(icon: "xmark", help: "Cancel (Esc)", action: onClose)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        .padding(16)
    }

    /// Buttons, not a menu: a menu would open underneath this screen-saver-level overlay.
    @ViewBuilder private var delay: some View {
        if state.kind == .snip {
            IconButton(icon: "timer", help: "Snip after a delay", selected: choosingDelay) { choosingDelay.toggle() }
            if choosingDelay {
                ForEach([3, 5, 10], id: \.self) { seconds in
                    IconButton(icon: "\(seconds).circle", help: "Snip in \(seconds) seconds") { onDelay(seconds) }
                }
            }
        } else {
            // A recording's delay is the countdown after Start, the same setting as on the record bar.
            IconButton(icon: "timer", help: "How long after you press Start the recording begins (click to change)",
                       label: recordDelay == 0 ? "Now" : "\(recordDelay)s", selected: recordDelay > 0) {
                let choices = Prefs.recordDelayChoices
                recordDelay = choices[((choices.firstIndex(of: recordDelay) ?? 0) + 1) % choices.count]
            }
        }
    }
}

extension CaptureBar {
    /// Development aid (`Snip dev-bar <out.png> [--record] [--delay]`): draws the bar to a PNG without
    /// showing it, as for snipping or recording and with the delay choices open, to check it by eye.
    @MainActor
    static func snapshot(to out: URL, kind: CaptureKind, choosingDelay: Bool) async -> Bool {
        let view = NSHostingView(rootView: CaptureBar(state: OverlayState(kind: kind, mode: .rect), choosingDelay: choosingDelay,
                                                      onDelay: { _ in }, onClose: {}))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.fittingSize), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = view
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        defer { window.close() }
        try? await Task.sleep(for: .milliseconds(600))
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: out)) != nil
    }
}
