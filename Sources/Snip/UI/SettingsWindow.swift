import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Snip Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            window = w
        }
        guard let window else { return }
        WindowTracker.track(window)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @AppStorage(Prefs.Key.autoCopy) private var autoCopy = true
    @AppStorage(Prefs.Key.showToast) private var showToast = true
    @AppStorage(Prefs.Key.openEditor) private var openEditor = true
    @AppStorage(Prefs.Key.autoSave) private var autoSave = true
    @AppStorage(Prefs.Key.fps) private var fps = 60
    @AppStorage(Prefs.Key.recordDelay) private var recordDelay = 3
    @AppStorage(Prefs.Key.speedrunOnScreen) private var speedrunOnScreen = true
    @AppStorage(Prefs.Key.speedrunOpacity) private var speedrunOpacity = 1.0
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var permission = Permission.screenRecordingAllowed

    var body: some View {
        Form {
            Section("Shortcuts") {
                LabeledContent("New snip") {
                    ShortcutRecorder(key: Prefs.Key.snipShortcut, fallback: .defaultSnip)
                }
                LabeledContent("Record screen") {
                    ShortcutRecorder(key: Prefs.Key.recordShortcut, fallback: .defaultRecord)
                }
                Text("Press the record shortcut again to stop a recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("After snipping") {
                Toggle("Copy to clipboard automatically", isOn: $autoCopy)
                Toggle("Show a preview in the corner", isOn: $showToast)
                Toggle("Open the editor right away", isOn: $openEditor)
                Toggle("Save snips to a folder", isOn: $autoSave)
                LabeledContent("Snips folder") {
                    FolderField(key: Prefs.Key.snipFolder, fallback: Prefs.defaultSnipFolder)
                }
            }

            Section("Screen recording") {
                Picker("Frame rate", selection: $fps) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                Picker("After pressing Start", selection: $recordDelay) {
                    ForEach(Prefs.recordDelayChoices, id: \.self) { d in
                        Text(d == 0 ? "Record right away" : "Count down \(d) seconds").tag(d)
                    }
                }
                LabeledContent("Recordings folder") {
                    FolderField(key: Prefs.Key.recordFolder, fallback: Prefs.defaultRecordFolder)
                }
            }

            Section("Speedrun timer") {
                Text("Turn it on with the 🏁 button next to the delay on the recording bar; ✏️ next to it edits the game and split names. Right-click the timer for splits files (LiveSplit .lss).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Show the timer on my screen", isOn: Binding(
                    get: { speedrunOnScreen },
                    set: { speedrunOnScreen = $0; SpeedrunController.shared.setOnScreen($0) }
                ))
                Text("It's in the recording either way. The 👁 button on the record bar (or \(Prefs.speedrunShortcut(.visibility).display)) switches this mid-run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Opacity") {
                    HStack {
                        Slider(value: Binding(
                            get: { speedrunOpacity },
                            set: { speedrunOpacity = $0; SpeedrunController.shared.setOpacity($0) }
                        ), in: 0.2...1)
                        Text("\(Int((speedrunOpacity * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                Text("How see-through the timer is, on your screen and in the recording. Also in the timer's right-click menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(SpeedrunAction.allCases, id: \.self) { action in
                    LabeledContent(action.title) {
                        ShortcutRecorder(key: Prefs.Key.speedrunShortcut(action), fallback: action.defaultShortcut)
                    }
                }
                Button("Edit Splits…") { SplitsEditorWindow.show() }
            }

            Section("General") {
                Toggle("Open Snip when you log in", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                LabeledContent("Screen recording permission") {
                    HStack {
                        Label(permission ? "Allowed" : "Not allowed",
                              systemImage: permission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(permission ? .green : .orange)
                        if !permission {
                            Button("Allow…") {
                                Permission.request()
                                permission = Permission.screenRecordingAllowed
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 680)
    }
}

/// Click, then press a key combination to set a global shortcut.
struct ShortcutRecorder: View {
    let key: String
    let fallback: Shortcut

    @State private var current: Shortcut
    @State private var recording = false
    @State private var monitor: Any?

    init(key: String, fallback: Shortcut) {
        self.key = key
        self.fallback = fallback
        _current = State(initialValue: Prefs.shortcut(key, fallback: fallback))
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(recording ? "Type a shortcut…" : current.display) {
                recording ? stopRecording() : startRecording()
            }
            .frame(minWidth: 130)
            if current != fallback {
                Button {
                    current = fallback
                    Prefs.setShortcut(nil, for: key)
                    HotKeys.install()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help("Back to \(fallback.display)")
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        recording = true
        HotKeyCenter.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
                return nil
            }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !mods.subtracting(.shift).isEmpty || Shortcut.worksAlone(event.keyCode) else {
                NSSound.beep()
                return nil
            }
            let shortcut = Shortcut(
                keyCode: UInt32(event.keyCode),
                modifiers: Shortcut.carbonModifiers(mods),
                display: Shortcut.symbols(mods) + Shortcut.keyName(event)
            )
            current = shortcut
            Prefs.setShortcut(shortcut, for: key)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        guard recording || monitor != nil else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        HotKeyCenter.shared.resume()
    }
}

struct FolderField: View {
    let key: String
    @AppStorage private var path: String

    init(key: String, fallback: URL) {
        self.key = key
        _path = AppStorage(wrappedValue: fallback.path, key)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text((path as NSString).abbreviatingWithTildeInPath)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
            Button("Change…") { choose() }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: path)
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
        }
    }
}

@MainActor
enum WelcomeWindow {
    private static var window: NSWindow?

    static func show() {
        let w = NSWindow(contentViewController: NSHostingController(rootView: WelcomeView(close: { window?.close() })))
        w.title = "Welcome to Snip"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        window = w
        WindowTracker.track(w)
        w.center()
        w.makeKeyAndOrderFront(nil)
    }
}

private struct WelcomeView: View {
    let close: () -> Void
    @State private var allowed = Permission.screenRecordingAllowed

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
            VStack(spacing: 6) {
                Text("Snip is ready").font(.title.bold())
                HStack(spacing: 4) {
                    Text("It lives in your menu bar — look for")
                    Image(systemName: "scissors")
                }
                .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                row(Prefs.snipShortcut.display, "Snip part of the screen. It's copied right away, so just paste.")
                row(Prefs.recordShortcut.display, "Record the screen. Press it again to stop.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            GroupBox {
                HStack(spacing: 10) {
                    Image(systemName: allowed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(allowed ? .green : .orange)
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Screen Recording permission").font(.headline)
                        Text(allowed ? "All set." : "macOS asks you to allow this once. Afterwards, reopen Snip.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !allowed {
                        Button("Allow…") {
                            Permission.request()
                            allowed = Permission.screenRecordingAllowed
                        }
                    }
                }
                .padding(6)
            }

            Button("Get started", action: close)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
        .padding(28)
        .frame(width: 460)
    }

    private func row(_ keys: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(keys)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
                .frame(width: 64)
            Text(text)
        }
    }
}
