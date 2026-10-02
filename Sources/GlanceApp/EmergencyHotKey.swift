import AppKit
import Carbon.HIToolbox

/// System-wide ⌃⌥⌘G to stop tracking without needing the pointer.
///
/// The user must always have direct access to stop tracking. Once the
/// app moves the cursor, "click the menu bar" is no longer a guarantee — the
/// pointer is the thing that may be misbehaving. This path needs no pointer.
///
/// Uses Carbon's `RegisterEventHotKey` rather than an `NSEvent` global monitor
/// because the Carbon API needs no Accessibility permission, and a safety
/// control that depends on a permission the user might not have granted is not
/// a safety control.
@MainActor
final class EmergencyHotKey {
    static let displayName = "⌃⌥⌘G"

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    init?(action: @escaping () -> Void) {
        pendingAction = action

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        guard InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { pendingAction?() }
            return noErr
        }, 1, &spec, nil, &handler) == noErr else { return nil }

        let id = EventHotKeyID(signature: OSType(0x475A_4744), id: 1)  // 'GLNC'
        guard RegisterEventHotKey(
            UInt32(kVK_ANSI_G),
            UInt32(controlKey | optionKey | cmdKey),
            id, GetApplicationEventTarget(), 0, &hotKey
        ) == noErr else {
            if let handler { RemoveEventHandler(handler) }
            return nil
        }
    }

    /// Explicit rather than `deinit`: a nonisolated deinit cannot touch these
    /// non-Sendable Carbon handles under strict concurrency.
    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
        pendingAction = nil
    }
}

/// The hot-key callback is a C function pointer and cannot capture context.
nonisolated(unsafe) private var pendingAction: (() -> Void)?
