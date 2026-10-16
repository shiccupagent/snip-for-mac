import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut, stored with Carbon key codes and modifiers.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var display: String

    static let defaultSnip = Shortcut(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(optionKey | shiftKey), display: "⌥⇧S")
    static let defaultRecord = Shortcut(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(optionKey | shiftKey), display: "⌥⇧R")

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }

    /// The key as a menu key equivalent, when it is a single character.
    var menuKeyEquivalent: String? {
        let key = display.drop { "⌃⌥⇧⌘".contains($0) }
        return key.count == 1 ? key.lowercased() : nil
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    static func symbols(_ flags: NSEvent.ModifierFlags) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }

    static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    /// Number-pad keys, LiveSplit's usual split keys. Like F-keys they work without modifiers.
    static let keypadKeys: [Int: String] = [
        kVK_ANSI_Keypad0: "Num 0", kVK_ANSI_Keypad1: "Num 1", kVK_ANSI_Keypad2: "Num 2", kVK_ANSI_Keypad3: "Num 3",
        kVK_ANSI_Keypad4: "Num 4", kVK_ANSI_Keypad5: "Num 5", kVK_ANSI_Keypad6: "Num 6", kVK_ANSI_Keypad7: "Num 7",
        kVK_ANSI_Keypad8: "Num 8", kVK_ANSI_Keypad9: "Num 9", kVK_ANSI_KeypadDecimal: "Num .",
        kVK_ANSI_KeypadPlus: "Num +", kVK_ANSI_KeypadMinus: "Num −", kVK_ANSI_KeypadMultiply: "Num ×",
        kVK_ANSI_KeypadDivide: "Num ÷", kVK_ANSI_KeypadEnter: "Num ↩",
    ]

    /// Keys that make a shortcut on their own, with no modifier held.
    static func worksAlone(_ keyCode: UInt16) -> Bool {
        functionKeys[Int(keyCode)] != nil || keypadKeys[Int(keyCode)] != nil
    }

    static func keyName(_ event: NSEvent) -> String {
        let code = Int(event.keyCode)
        if let f = functionKeys[code] { return f }
        if let k = keypadKeys[code] { return k }
        switch code {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default:
            return (event.characters(byApplyingModifiers: []) ?? "?").uppercased()
        }
    }
}

enum Prefs {
    static let defaults = UserDefaults.standard

    enum Key {
        static let autoCopy = "autoCopy"
        static let showToast = "showToast"
        // Renamed from "openEditorAfterSnip" when the default flipped to true, so existing installs get it too.
        static let openEditor = "editorAfterSnip"
        static let autoSave = "autoSave"
        static let snipFolder = "snipFolder"
        static let recordFolder = "recordFolder"
        static let fps = "recordFPS"
        static let mic = "recordMic"
        static let systemAudio = "recordSystemAudio"
        static let recordDelay = "recordDelay"
        static let snipShortcut = "snipShortcut"
        static let recordShortcut = "recordShortcut"
        static let snipMode = "snipMode"
        static let launchedBefore = "launchedBefore"
        static let speedrunTimer = "speedrunTimer"
        static let speedrunOnScreen = "speedrunOnScreen"
        static let splitsPath = "speedrunSplitsPath"
        static func speedrunShortcut(_ action: SpeedrunAction) -> String { "speedrunKey.\(action.rawValue)" }
    }

    static var defaultSnipFolder: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("Snips", isDirectory: true)
    }

    static var defaultRecordFolder: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Snips", isDirectory: true)
    }

    static func register() {
        defaults.register(defaults: [
            Key.autoCopy: true,
            Key.showToast: true,
            Key.openEditor: true,
            Key.autoSave: true,
            Key.snipFolder: defaultSnipFolder.path,
            Key.recordFolder: defaultRecordFolder.path,
            Key.fps: 60,
            Key.mic: false,
            Key.systemAudio: true,
            Key.recordDelay: 3,
            Key.snipMode: SnipMode.rect.rawValue,
            Key.speedrunTimer: false,
            Key.speedrunOnScreen: true,
        ])
    }

    static var autoCopy: Bool { defaults.bool(forKey: Key.autoCopy) }
    static var showToast: Bool { defaults.bool(forKey: Key.showToast) }
    static var openEditor: Bool { defaults.bool(forKey: Key.openEditor) }
    static var autoSave: Bool { defaults.bool(forKey: Key.autoSave) }
    static var recordFPS: Int { max(15, defaults.integer(forKey: Key.fps)) }

    static var snipFolder: URL {
        URL(fileURLWithPath: defaults.string(forKey: Key.snipFolder) ?? defaultSnipFolder.path, isDirectory: true)
    }

    static var recordFolder: URL {
        URL(fileURLWithPath: defaults.string(forKey: Key.recordFolder) ?? defaultRecordFolder.path, isDirectory: true)
    }

    static var recordMic: Bool {
        get { defaults.bool(forKey: Key.mic) }
        set { defaults.set(newValue, forKey: Key.mic) }
    }

    static var recordSystemAudio: Bool {
        get { defaults.bool(forKey: Key.systemAudio) }
        set { defaults.set(newValue, forKey: Key.systemAudio) }
    }

    /// Seconds between pressing Start and the recording beginning (0 = straight away).
    static var recordDelay: Int {
        get { max(0, defaults.integer(forKey: Key.recordDelay)) }
        set { defaults.set(newValue, forKey: Key.recordDelay) }
    }

    static let recordDelayChoices = [0, 3, 5, 10]

    static var snipMode: SnipMode {
        get { SnipMode(rawValue: defaults.string(forKey: Key.snipMode) ?? "") ?? .rect }
        set { defaults.set(newValue.rawValue, forKey: Key.snipMode) }
    }

    static var launchedBefore: Bool {
        get { defaults.bool(forKey: Key.launchedBefore) }
        set { defaults.set(newValue, forKey: Key.launchedBefore) }
    }

    /// The speedrun timer toggle on the recording bar.
    static var speedrunTimer: Bool {
        get { defaults.bool(forKey: Key.speedrunTimer) }
        set { defaults.set(newValue, forKey: Key.speedrunTimer) }
    }

    /// Off: the timer is hidden while playing and appears only in the recording.
    static var speedrunOnScreen: Bool {
        get { defaults.bool(forKey: Key.speedrunOnScreen) }
        set { defaults.set(newValue, forKey: Key.speedrunOnScreen) }
    }

    /// The splits file the timer loads and saves (LiveSplit .lss).
    static var splitsURL: URL {
        get { defaults.string(forKey: Key.splitsPath).map { URL(fileURLWithPath: $0) } ?? defaultSplitsURL(named: "Splits") }
        set { defaults.set(newValue.path, forKey: Key.splitsPath) }
    }

    static func defaultSplitsURL(named name: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Snip/Splits", isDirectory: true)
            .appendingPathComponent(name).appendingPathExtension("lss")
    }

    static func speedrunShortcut(_ action: SpeedrunAction) -> Shortcut {
        shortcut(Key.speedrunShortcut(action), fallback: action.defaultShortcut)
    }

    static var snipShortcut: Shortcut { shortcut(Key.snipShortcut, fallback: .defaultSnip) }
    static var recordShortcut: Shortcut { shortcut(Key.recordShortcut, fallback: .defaultRecord) }

    static func shortcut(_ key: String, fallback: Shortcut) -> Shortcut {
        guard let data = defaults.data(forKey: key),
              let s = try? JSONDecoder().decode(Shortcut.self, from: data) else { return fallback }
        return s
    }

    static func setShortcut(_ s: Shortcut?, for key: String) {
        if let s, let data = try? JSONEncoder().encode(s) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
