// SPDX-License-Identifier: GPL-3.0-only
import Carbon.HIToolbox
import Foundation

/// Global hotkeys through Carbon's RegisterEventHotKey.
///
/// This is the one job on macOS where the old Carbon API is still the right answer: it is the only
/// way to claim a system-wide combination without installing an event tap, which means TextFix can
/// own a hotkey *without* asking for Accessibility permission just to notice it was pressed. The
/// permission is still needed to read and replace the text, but the difference matters - a user who
/// has not granted it yet gets a useful explanation on the first press instead of silence.
final class HotkeyManager {
    /// Per-registration identity handed back to us in the event callback. The `id` is the index of
    /// the action in config.actions.
    private static let signature: OSType = 0x54_46_49_58 // 'TFIX'

    private var handlerRef: EventHandlerRef?
    private var registered: [EventHotKeyRef] = []
    private var onPressed: ((Int) -> Void)?

    deinit { uninstall() }

    func install(onPressed: @escaping (Int) -> Void) {
        self.onPressed = onPressed
        guard handlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(), hotkeyEventHandler, 1, &eventType, context, &handlerRef)
        if status != noErr {
            Log.error("Could not install the hotkey handler (OSStatus \(status))")
        }
    }

    func uninstall() {
        unregisterAll()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    /// Registers every binding it is given and returns the ones the system refused, so the caller
    /// can tell the user which action has no working hotkey rather than leaving them to discover it.
    @discardableResult
    func register(_ bindings: [(index: Int, binding: HotkeyBinding)]) -> [Int] {
        unregisterAll()
        var failed: [Int] = []
        for (index, binding) in bindings where !binding.isEmpty {
            var hotKeyRef: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: HotkeyManager.signature, id: UInt32(index))
            let status = RegisterEventHotKey(
                binding.keyCode, binding.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
            if status == noErr, let hotKeyRef {
                registered.append(hotKeyRef)
            } else {
                Log.warn("Hotkey \(binding.format()) was refused (OSStatus \(status))")
                failed.append(index)
            }
        }
        return failed
    }

    func unregisterAll() {
        for hotKeyRef in registered { UnregisterEventHotKey(hotKeyRef) }
        registered.removeAll(keepingCapacity: true)
    }

    fileprivate func fire(_ index: Int) { onPressed?(index) }
}

/// A plain top-level function so it can be used as a C function pointer: Carbon has no notion of a
/// Swift closure, and the instance travels through the userData pointer instead.
private func hotkeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID)
    guard status == noErr else { return status }

    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    manager.fire(Int(hotKeyID.id))
    return noErr
}
