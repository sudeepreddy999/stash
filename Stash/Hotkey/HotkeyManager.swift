import AppKit
import Carbon.HIToolbox

struct Hotkey: Codable, Equatable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon modifier mask (cmdKey, optionKey, controlKey, shiftKey)

    static let `default` = Hotkey(keyCode: UInt32(kVK_ANSI_V),
                                  modifiers: UInt32(cmdKey | shiftKey))

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        s += Hotkey.keyName(for: keyCode)
        return s
    }

    static func keyName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_G: return "G"
        case kVK_Space: return "Space"
        case kVK_ANSI_Grave: return "`"
        default: return "?"
        }
    }
}

@MainActor
final class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    var onTrigger: (() -> Void)?

    private static var shared: HotkeyManager?

    /// Returns `false` when the system refuses the combination — typically
    /// because another app already owns it. Callers surface that instead of
    /// leaving the user with a shortcut that silently does nothing.
    @discardableResult
    func register(_ hotkey: Hotkey) -> Bool {
        unregister()
        HotkeyManager.shared = self

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_, _, _) -> OSStatus in
            DispatchQueue.main.async {
                HotkeyManager.shared?.onTrigger?()
            }
            return noErr
        }, 1, &eventSpec, nil, &handlerRef)

        let hotKeyID = EventHotKeyID(signature: OSType(0x53544153), id: 1) // 'STAS'
        let status = RegisterEventHotKey(hotkey.keyCode,
                                         hotkey.modifiers,
                                         hotKeyID,
                                         GetApplicationEventTarget(),
                                         0,
                                         &hotKeyRef)
        if status != noErr || hotKeyRef == nil {
            NSLog("Stash: failed to register hotkey \(hotkey.display) (status \(status))")
            return false
        }
        return true
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let ref = handlerRef {
            RemoveEventHandler(ref)
            handlerRef = nil
        }
    }
}
