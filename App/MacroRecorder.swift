import AppKit
import ApplicationServices
import Carbon.HIToolbox
import KeycraftCore

/// Records key presses for a macro. While recording, a session event tap swallows every key event, so shortcuts
/// like ⌘Space or ⌘Q go into the macro instead of acting on the Mac. Needs Accessibility permission (an event
/// tap that blocks events can't run without it). Mouse clicks still work, so Stop is always reachable; recording
/// also stops after two minutes or if Keycraft stops being the active app.
@MainActor @Observable
final class MacroRecorder {
    static let shared = MacroRecorder()
    static let timeLimit: Duration = .seconds(120)

    private(set) var isRecording = false
    /// Raw presses and releases so far, in order.
    private(set) var steps: [MacroStep] = []
    private var held: [UInt8] = []

    @ObservationIgnored private var tap: CFMachPort?
    @ObservationIgnored private var source: CFRunLoopSource?
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private var resignObserver: NSObjectProtocol?
    @ObservationIgnored private var onStop: (([MacroStep]) -> Void)?

    static var hasPermission: Bool { AXIsProcessTrusted() }
    /// Shows macOS's own prompt, which offers to open Privacy & Security ▸ Accessibility.
    static func requestPermission() {
        // The value of kAXTrustedCheckOptionPrompt; the global itself isn't concurrency-safe to read.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
    /// A password field in another app turns this on, and then no app can see key presses.
    static var secureInputIsOn: Bool { IsSecureEventInputEnabled() }

    /// Starts recording; `onStop` gets the tidied steps. Returns false if the tap couldn't be created
    /// (usually: no Accessibility permission).
    @discardableResult
    func start(onStop: @escaping ([MacroStep]) -> Void) -> Bool {
        guard !isRecording else { return true }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        var mask = types.reduce(CGEventMask(0)) { $0 | 1 << $1.rawValue }
        mask |= 1 << 14   // NX_SYSDEFINED: volume, brightness and media keys
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: macroTapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        (steps, held, isRecording, self.onStop) = ([], [], true, onStop)
        timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.timeLimit)
            if !Task.isCancelled { self?.stop() }
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        return true
    }

    func stop() {
        guard isRecording else { return }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        (tap, source) = (nil, nil)
        timeout?.cancel()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        isRecording = false
        // Release anything still held, so the macro never leaves a key stuck down on the keyboard.
        for kc in held.reversed() { steps.append(.up(kc)) }
        held = []
        let finished = Macros.simplify(steps)
        let callback = onStop
        onStop = nil
        callback?(finished)
    }

    /// Steps so far, tidied, for the live preview.
    var preview: [MacroStep] { Macros.simplify(steps) }

    // MARK: Events (called on the main run loop)

    fileprivate func handle(_ e: TapEvent) -> Bool {
        switch e.type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        case .keyDown:
            guard !e.isRepeat else { return true }
            if let kc = Self.keys[e.keyCode] { press(kc) }
            return true
        case .keyUp:
            if let kc = Self.keys[e.keyCode] { release(kc) }
            return true
        case .flagsChanged:
            guard let kc = Self.keys[e.keyCode] else { return true }   // Fn / Globe has no keyboard-side equivalent
            if kc == 0x39 { press(kc); release(kc) }                   // Caps Lock reports once per press
            else if held.contains(kc) { release(kc) } else { press(kc) }
            return true
        default:
            guard let data = e.mediaData else { return false }
            let (key, state) = ((data & 0xFFFF0000) >> 16, (data & 0xFF00) >> 8)
            guard let kc = Self.media[key] else { return true }
            if state == 0x0A { if !held.contains(kc) { press(kc) } } else if state == 0x0B { release(kc) }
            return true
        }
    }

    private func press(_ kc: UInt8) {
        held.append(kc)
        steps.append(.down(kc))
    }

    private func release(_ kc: UInt8) {
        guard held.contains(kc) else { return }   // its press happened before recording started
        held.removeAll { $0 == kc }
        steps.append(.up(kc))
    }

    // MARK: Mac key codes to USB HID (QMK basic keycodes)

    /// Carbon kVK_* virtual key codes (HIToolbox Events.h) to HID usages.
    private static let keys: [Int: UInt8] = [
        kVK_ANSI_A: 0x04, kVK_ANSI_B: 0x05, kVK_ANSI_C: 0x06, kVK_ANSI_D: 0x07, kVK_ANSI_E: 0x08, kVK_ANSI_F: 0x09,
        kVK_ANSI_G: 0x0A, kVK_ANSI_H: 0x0B, kVK_ANSI_I: 0x0C, kVK_ANSI_J: 0x0D, kVK_ANSI_K: 0x0E, kVK_ANSI_L: 0x0F,
        kVK_ANSI_M: 0x10, kVK_ANSI_N: 0x11, kVK_ANSI_O: 0x12, kVK_ANSI_P: 0x13, kVK_ANSI_Q: 0x14, kVK_ANSI_R: 0x15,
        kVK_ANSI_S: 0x16, kVK_ANSI_T: 0x17, kVK_ANSI_U: 0x18, kVK_ANSI_V: 0x19, kVK_ANSI_W: 0x1A, kVK_ANSI_X: 0x1B,
        kVK_ANSI_Y: 0x1C, kVK_ANSI_Z: 0x1D,
        kVK_ANSI_1: 0x1E, kVK_ANSI_2: 0x1F, kVK_ANSI_3: 0x20, kVK_ANSI_4: 0x21, kVK_ANSI_5: 0x22, kVK_ANSI_6: 0x23,
        kVK_ANSI_7: 0x24, kVK_ANSI_8: 0x25, kVK_ANSI_9: 0x26, kVK_ANSI_0: 0x27,
        kVK_Return: 0x28, kVK_Escape: 0x29, kVK_Delete: 0x2A, kVK_Tab: 0x2B, kVK_Space: 0x2C,
        kVK_ANSI_Minus: 0x2D, kVK_ANSI_Equal: 0x2E, kVK_ANSI_LeftBracket: 0x2F, kVK_ANSI_RightBracket: 0x30,
        kVK_ANSI_Backslash: 0x31, kVK_ANSI_Semicolon: 0x33, kVK_ANSI_Quote: 0x34, kVK_ANSI_Grave: 0x35,
        kVK_ANSI_Comma: 0x36, kVK_ANSI_Period: 0x37, kVK_ANSI_Slash: 0x38, kVK_CapsLock: 0x39, kVK_ISO_Section: 0x64,
        kVK_F1: 0x3A, kVK_F2: 0x3B, kVK_F3: 0x3C, kVK_F4: 0x3D, kVK_F5: 0x3E, kVK_F6: 0x3F, kVK_F7: 0x40, kVK_F8: 0x41,
        kVK_F9: 0x42, kVK_F10: 0x43, kVK_F11: 0x44, kVK_F12: 0x45, kVK_F13: 0x68, kVK_F14: 0x69, kVK_F15: 0x6A,
        kVK_F16: 0x6B, kVK_F17: 0x6C, kVK_F18: 0x6D, kVK_F19: 0x6E, kVK_F20: 0x6F,
        kVK_Help: 0x49, kVK_Home: 0x4A, kVK_PageUp: 0x4B, kVK_ForwardDelete: 0x4C, kVK_End: 0x4D, kVK_PageDown: 0x4E,
        kVK_RightArrow: 0x4F, kVK_LeftArrow: 0x50, kVK_DownArrow: 0x51, kVK_UpArrow: 0x52,
        kVK_ANSI_KeypadClear: 0x53, kVK_ANSI_KeypadDivide: 0x54, kVK_ANSI_KeypadMultiply: 0x55, kVK_ANSI_KeypadMinus: 0x56,
        kVK_ANSI_KeypadPlus: 0x57, kVK_ANSI_KeypadEnter: 0x58, kVK_ANSI_Keypad1: 0x59, kVK_ANSI_Keypad2: 0x5A,
        kVK_ANSI_Keypad3: 0x5B, kVK_ANSI_Keypad4: 0x5C, kVK_ANSI_Keypad5: 0x5D, kVK_ANSI_Keypad6: 0x5E,
        kVK_ANSI_Keypad7: 0x5F, kVK_ANSI_Keypad8: 0x60, kVK_ANSI_Keypad9: 0x61, kVK_ANSI_Keypad0: 0x62,
        kVK_ANSI_KeypadDecimal: 0x63, kVK_ANSI_KeypadEquals: 0x67, kVK_ContextualMenu: 0x65,
        kVK_JIS_KeypadComma: 0x85, kVK_JIS_Underscore: 0x87, kVK_JIS_Yen: 0x89, kVK_JIS_Kana: 0x90, kVK_JIS_Eisu: 0x91,
        kVK_Control: 0xE0, kVK_Shift: 0xE1, kVK_Option: 0xE2, kVK_Command: 0xE3,
        kVK_RightControl: 0xE4, kVK_RightShift: 0xE5, kVK_RightOption: 0xE6, kVK_RightCommand: 0xE7,
    ]

    /// NX_KEYTYPE_* (IOKit ev_keymap.h) to QMK media keycodes.
    private static let media: [Int: UInt8] = [
        0: 0xA9, 1: 0xAA, 7: 0xA8,          // sound up, sound down, mute
        2: 0xBD, 3: 0xBE,                    // brightness up, down
        16: 0xAE, 17: 0xAB, 18: 0xAC,        // play, next, previous
    ]
}

/// What the recorder needs from one event, read before handing it to the main actor.
fileprivate struct TapEvent: Sendable {
    let type: CGEventType
    let keyCode: Int
    let isRepeat: Bool
    let mediaData: Int?   // NX_SYSDEFINED media key data1, for subtype 8 only
}

/// The tap's C callback. It runs on the main run loop, where the tap's source was added.
private func macroTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    var media: Int?
    if type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 { media = ns.data1 }
    let e = TapEvent(type: type, keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)),
                     isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0, mediaData: media)
    let recorder = Unmanaged<MacroRecorder>.fromOpaque(userInfo).takeUnretainedValue()
    let swallow = MainActor.assumeIsolated { recorder.handle(e) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
