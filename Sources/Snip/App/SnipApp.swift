import AppKit

@main
enum SnipMain {
    @MainActor
    static func main() {
        // Command-line modes (no UI): `speedrun` re-times recorded runs, `video` looks at and edits
        // recordings, `mcp` serves both to AI apps. Guide: docs/AI-EDITING.md.
        let command = CommandLine.arguments.dropFirst().first
        if let command, ["speedrun", "video", "mcp"].contains(command) {
            NSApplication.shared.setActivationPolicy(.prohibited)
            Prefs.register()
            let rest = Array(CommandLine.arguments.dropFirst(2))
            Task { @MainActor in
                switch command {
                case "speedrun": exit(await SpeedrunCLI.run(rest))
                case "video": exit(await VideoCLI.run(rest))
                default: exit(await MCPServer.run())
                }
            }
            RunLoop.main.run()
        }
        if command == "dev-snapshot", CommandLine.arguments.count >= 4 {
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.finishLaunching()
            Prefs.register()
            let args = CommandLine.arguments
            Task { @MainActor in
                let ok = await VideoWindowController.snapshot(url: URL(fileURLWithPath: args[2]), to: URL(fileURLWithPath: args[3]),
                                                              sampleEdit: args.contains("--edit"),
                                                              zoom: args.firstIndex(of: "--zoom").flatMap { args.indices.contains($0 + 1) ? Double(args[$0 + 1]) : nil })
                exit(ok ? 0 : 1)
            }
            RunLoop.main.run()
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.register()
        try? FileManager.default.removeItem(at: FileNamer.tempFolder)
        MainMenu.install()
        setupStatusItem()
        HotKeys.install()
        for name in [NSApplication.didHideNotification, NSApplication.didResignActiveNotification, NSApplication.didBecomeActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                captureLog.notice("app \(note.name.rawValue, privacy: .public)")
            }
        }
        CaptureCoordinator.shared.onRecordingChanged = { [weak self] recording in
            self?.updateStatusItem(recording: recording)
        }
        if !Prefs.launchedBefore {
            Prefs.launchedBefore = true
            WelcomeWindow.show()
        } else if !launchedAtLogin {
            // Opening Snip means "take a snip", like the Windows Snipping Tool shortcut.
            newSnip()
        }
    }

    /// Opening Snip again (Finder, Spotlight, Launchpad) while it's running also goes straight to the capture bar.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        captureLog.notice("reopen, visible windows: \(flag)")
        if !flag { newSnip() }
        return true
    }

    /// Login launches stay quiet in the menu bar.
    private var launchedAtLogin: Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        if event?.eventID == AEEventID(kAEOpenApplication),
           event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem) {
            return true
        }
        return ProcessInfo.processInfo.systemUptime < 120
    }

    // MARK: Menu bar icon

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusMenu.delegate = self
        updateStatusItem(recording: false)
    }

    private func updateStatusItem(recording: Bool) {
        guard let button = statusItem.button else { return }
        if recording {
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
                .applying(.init(hierarchicalColor: .systemRed))
            let image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop recording")?
                .withSymbolConfiguration(config)
            image?.isTemplate = false
            button.image = image
            button.toolTip = "Stop recording"
            statusItem.menu = nil
            button.target = self
            button.action = #selector(stopRecording)
        } else {
            let image = NSImage(systemSymbolName: "scissors", accessibilityDescription: "Snip")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Snip"
            button.action = nil
            statusItem.menu = statusMenu
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let snip = item("New Snip", #selector(newSnip), shortcut: Prefs.snipShortcut)
        snip.image = NSImage(systemSymbolName: "camera", accessibilityDescription: nil)
        menu.addItem(snip)
        let rec = item("Record Screen", #selector(recordScreen), shortcut: Prefs.recordShortcut)
        rec.image = NSImage(systemSymbolName: "video", accessibilityDescription: nil)
        menu.addItem(rec)

        let delayItem = NSMenuItem(title: "Snip with Delay", action: nil, keyEquivalent: "")
        delayItem.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)
        let delayMenu = NSMenu()
        for seconds in [3, 5, 10] {
            let d = item("In \(seconds) seconds", #selector(delayedSnip(_:)))
            d.tag = seconds
            delayMenu.addItem(d)
        }
        delayItem.submenu = delayMenu
        menu.addItem(delayItem)

        let edit = item("Edit a Recording…", #selector(editRecording))
        edit.image = NSImage(systemSymbolName: "film", accessibilityDescription: nil)
        menu.addItem(edit)

        menu.addItem(.separator())
        menu.addItem(item("Open Snips Folder", #selector(openSnips)))
        menu.addItem(item("Open Recordings Folder", #selector(openRecordings)))
        menu.addItem(.separator())
        let settings = item("Settings…", #selector(showSettings))
        settings.keyEquivalent = ","
        menu.addItem(settings)
        let quit = NSMenuItem(title: "Quit Snip", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func item(_ title: String, _ action: Selector, shortcut: Shortcut? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let shortcut, let key = shortcut.menuKeyEquivalent {
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = shortcut.modifierFlags
        }
        return item
    }

    @objc func newSnip() { CaptureCoordinator.shared.begin(.snip, after: 0.25) }
    @objc func recordScreen() { CaptureCoordinator.shared.begin(.record, after: 0.25) }
    @objc func delayedSnip(_ sender: NSMenuItem) { CaptureCoordinator.shared.begin(.snip, delay: sender.tag) }
    @objc func openSnips() { openFolder(Prefs.snipFolder) }
    @objc func openRecordings() { openFolder(Prefs.recordFolder) }

    /// Opens any recording (or other video) in the timeline editor.
    @objc func editRecording() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        panel.directoryURL = Prefs.recordFolder
        panel.prompt = "Edit"
        panel.message = "Choose a recording to edit"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        VideoWindowController.edit(url)
    }

    /// Videos dropped on Snip's icon, or opened with Open With → Snip, open in the timeline editor.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { VideoWindowController.edit(url) }
    }
    @objc func showSettings() { SettingsWindow.show() }
    @objc func stopRecording() { CaptureCoordinator.shared.recording?.stopOrCancel() }

    private func openFolder(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
}

@MainActor
enum HotKeys {
    static func install() {
        let center = HotKeyCenter.shared
        center.register(id: 1, shortcut: Prefs.snipShortcut) {
            CaptureCoordinator.shared.begin(.snip)
        }
        center.register(id: 2, shortcut: Prefs.recordShortcut) {
            CaptureCoordinator.shared.recordHotkey()
        }
        SpeedrunKeys.reinstallIfShowing()
    }
}

@MainActor
enum MainMenu {
    static func install() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Snip", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Snip", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Snip", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(appMenu, title: "Snip", to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(edit, title: "Edit", to: main)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        add(window, title: "Window", to: main)
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }

    private static func add(_ menu: NSMenu, title: String, to main: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.title = title
        item.submenu = menu
        main.addItem(item)
    }
}

/// Shows a Dock icon while any Snip window is open, and hides it again when the last one closes.
@MainActor
enum WindowTracker {
    private(set) static var windows: [NSWindow] = []
    private static var observers: [ObjectIdentifier: NSObjectProtocol] = [:]

    static func track(_ window: NSWindow) {
        if !windows.contains(where: { $0 === window }) {
            windows.append(window)
            observers[ObjectIdentifier(window)] = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { _ in
                MainActor.assumeIsolated { untrack(window) }
            }
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func untrack(_ window: NSWindow) {
        windows.removeAll { $0 === window }
        if let token = observers.removeValue(forKey: ObjectIdentifier(window)) {
            NotificationCenter.default.removeObserver(token)
        }
        if windows.isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
