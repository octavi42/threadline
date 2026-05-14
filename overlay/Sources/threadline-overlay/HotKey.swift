import AppKit
import Carbon.HIToolbox

/// Carbon-based global hotkey. Works without any macOS permission prompt
/// (no Accessibility, no Input Monitoring) — the trade-off is that it's a
/// fixed-key hook, not a free-form keylogger.
///
/// Default binding: ⌃⌥⌘T (control + option + command + T). Override via the
/// `THREADLINE_HOTKEY` env var (e.g. `cmd+shift+t`, `ctrl+opt+cmd+\\`).
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onPress: () -> Void

    init(onPress: @escaping () -> Void) {
        self.onPress = onPress
    }

    deinit {
        if let h = hotKeyRef    { UnregisterEventHotKey(h) }
        if let h = handlerRef   { RemoveEventHandler(h) }
    }

    /// Register the hotkey for the running app. Returns true on success.
    @discardableResult
    func register() -> Bool {
        let spec = parseEnvBinding() ?? Binding(modifiers: UInt32(controlKey | optionKey | cmdKey),
                                                 keyCode: UInt32(kVK_ANSI_T),
                                                 description: "⌃⌥⌘T")

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(),
                                         hotKeyCallback,
                                         1, &eventType,
                                         selfPtr,
                                         &handlerRef)
        guard status == noErr else {
            FileHandle.standardError.write(Data("hotkey: InstallEventHandler failed (\(status))\n".utf8))
            return false
        }
        let id = EventHotKeyID(signature: fourCharCode("THLN"), id: 1)
        let regStatus = RegisterEventHotKey(spec.keyCode,
                                            spec.modifiers,
                                            id,
                                            GetApplicationEventTarget(),
                                            0,
                                            &hotKeyRef)
        if regStatus != noErr {
            FileHandle.standardError.write(Data("hotkey: RegisterEventHotKey failed (\(regStatus))\n".utf8))
            return false
        }
        FileHandle.standardError.write(Data("hotkey: \(spec.description) → toggle\n".utf8))
        return true
    }

    fileprivate func fire() {
        DispatchQueue.main.async { [weak self] in self?.onPress() }
    }

    // MARK: - parsing

    private struct Binding {
        let modifiers: UInt32
        let keyCode: UInt32
        let description: String
    }

    private func parseEnvBinding() -> Binding? {
        guard let raw = ProcessInfo.processInfo.environment["THREADLINE_HOTKEY"]?.lowercased() else { return nil }
        let parts = raw.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyToken = parts.last, parts.count > 1 else { return nil }
        var modifiers: UInt32 = 0
        for token in parts.dropLast() {
            switch token {
            case "cmd", "command", "⌘":      modifiers |= UInt32(cmdKey)
            case "opt", "option", "alt", "⌥": modifiers |= UInt32(optionKey)
            case "ctrl", "control", "⌃":     modifiers |= UInt32(controlKey)
            case "shift", "⇧":               modifiers |= UInt32(shiftKey)
            default: return nil
            }
        }
        guard let kc = keyCode(for: keyToken) else { return nil }
        return Binding(modifiers: modifiers, keyCode: kc, description: raw)
    }

    private func keyCode(for token: String) -> UInt32? {
        // Letters + a few useful keys. Add more as needed.
        let letters: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
            "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
            "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
            "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
            "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            "space": kVK_Space, "tab": kVK_Tab, "return": kVK_Return,
            "`": kVK_ANSI_Grave, "\\": kVK_ANSI_Backslash,
            "f18": kVK_F18, "f19": kVK_F19, "f20": kVK_F20,
        ]
        if let kc = letters[token] { return UInt32(kc) }
        return nil
    }

    private func fourCharCode(_ str: String) -> OSType {
        var result: OSType = 0
        for scalar in str.unicodeScalars.prefix(4) {
            result = (result << 8) | OSType(scalar.value & 0xFF)
        }
        return result
    }
}

private func hotKeyCallback(callRef: EventHandlerCallRef?,
                            event: EventRef?,
                            userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let userData = userData else { return noErr }
    let hk = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
    hk.fire()
    return noErr
}
