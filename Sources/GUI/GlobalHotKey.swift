import AppKit
import Carbon.HIToolbox

// System-wide keyboard shortcut ("전역 단축키"). Fires no matter which app is frontmost —
// the whole point: the menu-bar app can be toggled without first bringing it forward.
//
// WHY Carbon RegisterEventHotKey and not an NSEvent global monitor / CGEventTap: those two
// need the Accessibility (입력 모니터링) grant, which this app deliberately never asks for.
// RegisterEventHotKey is the OS's own hotkey registry — no permission prompt, and it
// SWALLOWS the chord so it never reaches the frontmost app (⌘M would otherwise minimize
// that app's window, ⌥M would type µ into its text field). It is the same mechanism the
// system uses for its own shortcuts and is still fully supported on modern macOS.
//
// Registration is exclusive: if another app already owns the chord, init returns nil and
// the caller keeps working without the shortcut (no failure banner — see the app's
// "no user-facing failure" rule).
//
// App-agnostic like the rest of this target: no ConditionManager types, the handler is
// injected. Hold on to the instance — releasing it unregisters the hotkey.
public final class GlobalHotKey {

    // Carbon delivers hotkey presses to a C callback with no captured context, so the
    // instances park their handlers here, keyed by the id we hand to the OS.
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var dispatcher: EventHandlerRef?

    private let id: UInt32
    private var ref: EventHotKeyRef?

    /// Register `modifiers`+`keyCode` system-wide. `keyCode` is a hardware keycode
    /// (kVK_ANSI_M = 46) so the chord is layout- and input-source-independent: it still
    /// fires with a Korean input source active, where the typed character would be "ㅡ".
    /// Returns nil when the OS refuses the registration (chord already taken).
    public init?(keyCode: CGKeyCode, modifiers: NSEvent.ModifierFlags, handler: @escaping () -> Void) {
        GlobalHotKey.installDispatcher()
        id = GlobalHotKey.nextID
        GlobalHotKey.nextID += 1

        var hotKeyRef: EventHotKeyRef?
        // 'CMhk' — signature is only used to namespace our ids within the process.
        let hotKeyID = EventHotKeyID(signature: OSType(0x434D_686B), id: id)
        let status = RegisterEventHotKey(UInt32(keyCode),
                                        GlobalHotKey.carbonModifiers(modifiers),
                                        hotKeyID,
                                        GetApplicationEventTarget(),
                                        0,
                                        &hotKeyRef)
        guard status == noErr, let hotKeyRef else { return nil }
        ref = hotKeyRef
        GlobalHotKey.handlers[id] = handler
    }

    deinit { unregister() }

    /// Give the chord back to the system. Idempotent.
    public func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        GlobalHotKey.handlers.removeValue(forKey: id)
    }

    /// True while the OS still holds this registration.
    public var isRegistered: Bool { ref != nil }

    // MARK: Internals

    // NSEvent modifier flags -> Carbon's own bit layout (cmdKey/optionKey/...).
    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command)  { carbon |= UInt32(cmdKey) }
        if flags.contains(.option)   { carbon |= UInt32(optionKey) }
        if flags.contains(.control)  { carbon |= UInt32(controlKey) }
        if flags.contains(.shift)    { carbon |= UInt32(shiftKey) }
        return carbon
    }

    // One process-wide Carbon handler fans every hotkey press out to the right closure.
    private static func installDispatcher() {
        guard dispatcher == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        var handlerRef: EventHandlerRef?
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            let got = GetEventParameter(event,
                                        EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID),
                                        nil,
                                        MemoryLayout<EventHotKeyID>.size,
                                        nil,
                                        &pressed)
            guard got == noErr, let handler = GlobalHotKey.handlers[pressed.id] else {
                return OSStatus(eventNotHandledErr)
            }
            // Carbon runs this on the main run loop, so the handler can touch UI directly.
            handler()
            return noErr
        }, 1, &spec, nil, &handlerRef)
        if status == noErr { dispatcher = handlerRef }
    }
}
