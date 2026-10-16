import AppKit
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers

/// The speedrun timer inside Snip: a floating LiveSplit-style window shown while recording (when its
/// toggle on the recording bar is on), split keys that work while the game has focus, and the splits
/// file. Recordings never capture the window itself: the timer is drawn into every frame where the
/// window sits, so showing or hiding it on screen never changes the video.
@MainActor
final class SpeedrunController: ObservableObject {
    static let shared = SpeedrunController()

    let timer: SpeedrunTimer
    /// The timer as drawn into recordings.
    let recordingOverlay = TimerOverlay()
    /// Whether the timer is visible on screen (it's in the recording either way).
    @Published private(set) var onScreen = Prefs.speedrunOnScreen
    private var panel: TimerPanel?
    /// The name being typed over on the timer, if any.
    private let editing = TimerEditing()
    /// The app that had the keyboard before an edit, given it back afterwards.
    private var keyboardOwner: NSRunningApplication?
    private var active = false
    private var region: CGRect = .zero
    private var overlayTicker: Timer?
    private var overlayScale: CGFloat = 2
    /// How solid the timer is (Settings, or the slider in its right-click menu).
    private(set) var opacity = Prefs.speedrunOpacity
    private var log: RunLogBuilder?

    private init() {
        timer = SpeedrunTimer(splits: SpeedrunController.loadSplits(at: Prefs.splitsURL) ?? .blank)
        timer.onSplitsChanged = { splits in SpeedrunController.write(splits, to: Prefs.splitsURL) }
    }

    /// On while the recording bar's speedrun toggle is: split keys work and the timer is recorded.
    var isShowing: Bool { active }

    /// Puts the timer in the top-right corner of `region` (screen coordinates). `scale` is the
    /// display's pixels per point, for drawing the timer into recordings.
    func show(in region: CGRect, scale: CGFloat) {
        // Pick up a splits file replaced on disk (e.g. one copied over from LiveSplit).
        if timer.phase == .idle, let splits = SpeedrunController.loadSplits(at: Prefs.splitsURL) {
            timer.replaceSplits(splits)
        }
        active = true
        self.region = region
        overlayScale = scale
        SpeedrunKeys.register()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: TimerView.width, height: 300))
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: region.maxX - size.width - 8, y: region.maxY - size.height - 8))
        if onScreen { panel.orderFrontRegardless() }
        startOverlay()
    }

    /// Hides the timer; an attempt still running is reset so its golds are kept.
    func hide() {
        guard active else { return }
        endEdit(nil)
        active = false
        panel?.orderOut(nil)
        stopOverlay()
        SpeedrunKeys.unregister()
        timer.reset()
    }

    /// Shows or hides the timer on screen. It stays in the recording either way, so this works mid-run.
    func setOnScreen(_ visible: Bool) {
        onScreen = visible
        Prefs.speedrunOnScreen = visible
        guard active, let panel else { return }
        if !visible { endEdit(nil) }
        if visible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
    }

    func toggleOnScreen() { setOnScreen(!onScreen) }

    /// Makes the timer more or less see-through, on screen and in the recording alike.
    func setOpacity(_ value: Double) {
        Prefs.speedrunOpacity = value
        opacity = Prefs.speedrunOpacity
        panel?.alphaValue = opacity
    }

    private func startOverlay() {
        guard overlayTicker == nil else { return }
        renderOverlay()
        overlayTicker = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
            MainActor.assumeIsolated { SpeedrunController.shared.renderOverlay() }
        }
    }

    private func stopOverlay() {
        overlayTicker?.invalidate()
        overlayTicker = nil
        recordingOverlay.content = nil
    }

    /// Draws the timer for the recording, where its window sits in the recorded area (kept inside it).
    private func renderOverlay() {
        let renderer = ImageRenderer(content: TimerView(timer: timer, live: false).opacity(opacity))
        renderer.scale = overlayScale
        guard let image = renderer.cgImage else { return }
        let size = CGSize(width: CGFloat(image.width) / overlayScale, height: CGFloat(image.height) / overlayScale)
        let frame = panel?.frame ?? CGRect(x: region.maxX - size.width - 8, y: region.maxY - size.height - 8, width: size.width, height: size.height)
        let x = min(max(frame.minX - region.minX, 0), max(region.width - size.width, 0))
        let y = min(max(region.maxY - frame.maxY, 0), max(region.height - size.height, 0))
        recordingOverlay.content = (image, CGPoint(x: x, y: y))
    }

    func resize() {
        guard let panel, let size = panel.contentView?.fittingSize else { return }
        let top = panel.frame.maxY
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    // MARK: Editing names on the timer

    /// Double-click on the game, category or a split name: type over it in place.
    fileprivate func beginEdit(_ field: SplitsField) {
        guard let panel else { return }
        endEdit(editing.text)
        switch field {
        case .game: editing.text = timer.splits.game
        case .category: editing.text = timer.splits.category
        case .segment(let i):
            guard timer.splits.segments.indices.contains(i) else { return }
            editing.text = timer.splits.segments[i].name
        }
        // The timer never takes the keyboard from the game, except while a name is being typed.
        let front = NSWorkspace.shared.frontmostApplication
        keyboardOwner = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        panel.allowsKey = true
        panel.makeKeyAndOrderFront(nil)
        editing.field = field
    }

    /// Saves the typed name (nil: cancel) and gives the keyboard back.
    fileprivate func endEdit(_ name: String?) {
        guard let field = editing.field else { return }
        editing.field = nil
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines) {
            switch field {
            case .segment(let i):
                // A split needs a name; the game and category may be blank.
                if !name.isEmpty {
                    timer.rename(field, to: name)
                    log?.rename(i, to: name)
                }
            case .game, .category:
                timer.rename(field, to: name)
            }
        }
        if let panel {
            panel.allowsKey = false
            panel.resignKey()
        }
        keyboardOwner?.activate()
        keyboardOwner = nil
    }

    fileprivate var isEditing: Bool { editing.field != nil }

    private func makePanel() -> TimerPanel {
        let panel = TimerPanel(contentRect: NSRect(x: 0, y: 0, width: TimerView.width, height: 300),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.alphaValue = opacity
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = TimerHostingView(rootView: TimerView(timer: timer, editing: editing) { _, name in
            MainActor.assumeIsolated { SpeedrunController.shared.endEdit(name) }
        })
        host.menuProvider = { [weak self] in self?.contextMenu() ?? NSMenu() }
        host.editing = editing
        panel.contentView = host
        return panel
    }

    // MARK: Run log (for re-timing a recording later)

    /// Starts logging the runner's actions against `videoTime` (seconds into the recording).
    func startLog(videoTime: @escaping () -> Double) {
        let builder = RunLogBuilder()
        log = builder
        timer.onEvent = { [weak self] event in
            guard let self else { return }
            builder.record(event, splits: self.timer.splits, at: videoTime())
        }
    }

    /// Saves "<video>.speedrun.json" next to the recording.
    func finishLog(video: URL, clean: URL?, endTime: Double, pixelsPerPoint: CGFloat) {
        timer.onEvent = nil
        defer { log = nil }
        guard let log, let clean, !log.runs.isEmpty else { return }
        log.finish(at: endTime)
        let at = recordingOverlay.content?.offset ?? .zero
        let runLog = RunLog(
            video: video.lastPathComponent, cleanVideo: clean.lastPathComponent,
            game: timer.splits.game, category: timer.splits.category, offset: timer.splits.offset,
            timer: .init(x: at.x, y: at.y, scale: pixelsPerPoint, opacity: opacity < 1 ? opacity : nil), runs: log.runs
        )
        do {
            try runLog.data().write(to: RunLog.url(for: video), options: .atomic)
        } catch {
            NSLog("Snip: couldn't save the speedrun log: \(error)")
        }
    }

    func cancelLog() {
        timer.onEvent = nil
        log = nil
    }

    // MARK: Right-click menu (as in LiveSplit)

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ key: String? = nil, _ action: @escaping () -> Void) {
            let item = ClosureMenuItem(title: key.map { "\(title)    \($0)" } ?? title, action: action)
            menu.addItem(item)
        }
        add(timer.phase == .idle ? "Start" : "Split", Prefs.speedrunShortcut(.split).display) { [timer] in timer.split() }
        add("Undo Split", Prefs.speedrunShortcut(.undo).display) { [timer] in timer.undo() }
        add("Skip Split", Prefs.speedrunShortcut(.skip).display) { [timer] in timer.skip() }
        add(timer.phase == .paused ? "Resume" : "Pause", Prefs.speedrunShortcut(.pause).display) { [timer] in timer.togglePause() }
        add("Reset", Prefs.speedrunShortcut(.reset).display) { [timer] in timer.reset() }
        menu.addItem(.separator())
        let slider = NSMenuItem()
        slider.view = OpacityMenuView(value: opacity) { [weak self] in self?.setOpacity($0) }
        menu.addItem(slider)
        add("Hide on Screen (Still Recorded)", Prefs.speedrunShortcut(.visibility).display) { [weak self] in self?.setOnScreen(false) }
        add("Rename Game") { [weak self] in self?.beginEdit(.game) }
        add("Edit Splits…") { SplitsEditorWindow.show() }
        add("Open Splits…") { [weak self] in self?.openSplits() }
        add("Save Splits As…") { [weak self] in self?.saveSplitsAs() }
        add("New Splits") { [weak self] in self?.newSplits() }
        return menu
    }

    // MARK: Splits files

    func apply(_ splits: Splits) {
        timer.replaceSplits(splits)
        resize()
    }

    func openSplits() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "lss") ?? .xml]
        panel.directoryURL = Prefs.splitsURL.deletingLastPathComponent()
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let splits = try Splits(lss: Data(contentsOf: url))
            timer.reset()
            Prefs.splitsURL = url
            apply(splits)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func saveSplitsAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "lss") ?? .xml]
        let s = timer.splits
        panel.nameFieldStringValue = [s.game, s.category].filter { !$0.isEmpty }.joined(separator: " - ") + ".lss"
        panel.directoryURL = Prefs.splitsURL.deletingLastPathComponent()
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Prefs.splitsURL = url
        SpeedrunController.write(timer.splits, to: url)
    }

    func newSplits() {
        timer.reset()
        Prefs.splitsURL = Prefs.defaultSplitsURL(named: "Splits \(Int(Date().timeIntervalSince1970))")
        apply(.blank)
        SplitsEditorWindow.show()
    }

    private static func loadSplits(at url: URL) -> Splits? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Splits(lss: data)
    }

    private static func write(_ splits: Splits, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try splits.lssData().write(to: url, options: .atomic)
        } catch {
            NSLog("Snip: couldn't save splits to \(url.path): \(error)")
        }
    }
}

/// The latest picture of the timer, read by the recorder's capture queue.
final class TimerOverlay: @unchecked Sendable {
    private let lock = NSLock()
    private var _content: (image: CGImage, offset: CGPoint)?

    /// The picture and where its top-left goes, in points from the recorded area's top-left.
    var content: (image: CGImage, offset: CGPoint)? {
        get { lock.withLock { _content } }
        set { lock.withLock { _content = newValue } }
    }
}

/// The five LiveSplit actions with global keys. Defaults are LiveSplit's number-pad keys.
enum SpeedrunAction: String, CaseIterable {
    case split, undo, skip, pause, reset, visibility

    var title: String {
        switch self {
        case .split: return "Start / Split"
        case .undo: return "Undo split"
        case .skip: return "Skip split"
        case .pause: return "Pause"
        case .reset: return "Reset"
        case .visibility: return "Show / hide on screen"
        }
    }

    var defaultShortcut: Shortcut {
        switch self {
        case .split: return Shortcut(keyCode: UInt32(kVK_ANSI_Keypad1), modifiers: 0, display: "Num 1")
        case .skip: return Shortcut(keyCode: UInt32(kVK_ANSI_Keypad2), modifiers: 0, display: "Num 2")
        case .reset: return Shortcut(keyCode: UInt32(kVK_ANSI_Keypad3), modifiers: 0, display: "Num 3")
        case .pause: return Shortcut(keyCode: UInt32(kVK_ANSI_Keypad5), modifiers: 0, display: "Num 5")
        case .undo: return Shortcut(keyCode: UInt32(kVK_ANSI_Keypad8), modifiers: 0, display: "Num 8")
        case .visibility: return Shortcut(keyCode: UInt32(kVK_ANSI_Keypad9), modifiers: 0, display: "Num 9")
        }
    }

    var hotKeyID: UInt32 { 10 + UInt32(SpeedrunAction.allCases.firstIndex(of: self)!) }

    @MainActor func perform(_ timer: SpeedrunTimer) {
        switch self {
        case .split: timer.split()
        case .undo: timer.undo()
        case .skip: timer.skip()
        case .pause: timer.togglePause()
        case .reset: timer.reset()
        case .visibility: SpeedrunController.shared.toggleOnScreen()
        }
    }
}

/// Split keys are taken only while the timer is on screen, so the number pad works normally otherwise.
@MainActor
enum SpeedrunKeys {
    static func register() {
        let timer = SpeedrunController.shared.timer
        for action in SpeedrunAction.allCases {
            HotKeyCenter.shared.register(id: action.hotKeyID, shortcut: Prefs.speedrunShortcut(action)) {
                action.perform(timer)
            }
        }
    }

    static func unregister() {
        for action in SpeedrunAction.allCases { HotKeyCenter.shared.unregister(id: action.hotKeyID) }
    }

    /// After shortcuts are re-installed (e.g. changed in Settings), keep the split keys if showing.
    static func reinstallIfShowing() {
        if SpeedrunController.shared.isShowing { register() }
    }
}

/// The timer's window. It only takes the keyboard while a name on it is being typed.
final class TimerPanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
}

/// Hosts the timer: drags move the window, double-clicking a name edits it, right-click opens the
/// LiveSplit-style menu, and clicks never take focus from the game.
private final class TimerHostingView: NSHostingView<TimerView> {
    var menuProvider: (() -> NSMenu)?
    var editing: TimerEditing?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let controller = SpeedrunController.shared
        // A click off the name being edited saves it (clicks in its text field never reach here).
        if controller.isEditing { controller.endEdit(editing?.text) }
        let p = convert(event.locationInWindow, from: nil)
        let point = CGPoint(x: p.x, y: isFlipped ? p.y : bounds.height - p.y)
        if event.clickCount == 2, let field = editing?.target(at: point) {
            controller.beginEdit(field)
        } else {
            window?.performDrag(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

/// The opacity slider inside the timer's right-click menu: drag it and watch the timer change.
private final class OpacityMenuView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let slider: NSSlider
    private let onChange: (Double) -> Void

    init(value: Double, onChange: @escaping (Double) -> Void) {
        self.onChange = onChange
        slider = NSSlider(value: value, minValue: 0.2, maxValue: 1, target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 250, height: 46))
        label.font = .menuFont(ofSize: 0)
        label.frame = NSRect(x: 20, y: 25, width: 220, height: 17)
        slider.frame = NSRect(x: 18, y: 4, width: 214, height: 20)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changed)
        addSubview(label)
        addSubview(slider)
        showValue()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed() {
        onChange(slider.doubleValue)
        showValue()
    }

    private func showValue() {
        label.stringValue = "Opacity: \(Int((slider.doubleValue * 100).rounded()))%"
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
