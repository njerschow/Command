import AppKit
import Carbon

/// Registers and manages the global ⌘+. hotkey
final class HotkeyManager {
    private var eventHandler: EventHandlerRef?
    private var onTrigger: (() -> Void)?

    deinit {
        unregister()
    }

    /// Register ⌘+. as a global hotkey
    func register(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger

        // ⌘+. = command + period (keycode 47)
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x434D4421) // "CMD!"
        hotKeyID.id = 1

        var hotKeyRef: EventHotKeyRef?
        let modifiers: UInt32 = UInt32(cmdKey)
        let keyCode: UInt32 = 47 // period key

        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr else {
            print("[HotkeyManager] Failed to register hotkey: \(status)")
            return
        }

        // Install event handler
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                manager.onTrigger?()
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &eventHandler
        )
    }

    func unregister() {
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
    }
}
