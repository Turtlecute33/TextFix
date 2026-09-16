// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Carbon.HIToolbox

/// The agent's entire permanent presence on screen: one menu bar item and the menu behind it.
///
/// There is deliberately no Dock icon and no Cmd+Tab entry - see LSUIElement in Info.plist. TextFix
/// is something you press a key to use, not something you switch to, and an app you never switch to
/// has no business taking a Dock slot for the rest of the session.
final class StatusItem: NSObject, NSMenuDelegate {
    static let idleTooltip = "TextFix"

    private let item: NSStatusItem
    private var config: AppConfig
    private var paused = false
    /// Kept so the menu can be corrected as it opens without being rebuilt underneath itself,
    /// which is not something AppKit tolerates.
    private weak var grantPermissionItem: NSMenuItem?

    var onSettings: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onOpenConfigFolder: (() -> Void)?
    var onOpenLog: (() -> Void)?
    var onQuit: (() -> Void)?
    var onActionHint: ((Int) -> Void)?

    init(config: AppConfig) {
        self.config = config
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = item.button {
            button.image = AppIcons.statusBar
            button.imagePosition = .imageOnly
            button.toolTip = StatusItem.idleTooltip
            button.wantsLayer = true
        }
        // Survives the user dragging it around the menu bar and being relaunched.
        item.behavior = []
        item.isVisible = true
        rebuildMenu(config: config, paused: paused)
    }

    func update(config: AppConfig, paused: Bool) {
        self.config = config
        self.paused = paused
        rebuildMenu(config: config, paused: paused)
        setTooltip(paused ? "TextFix - hotkeys paused" : StatusItem.idleTooltip)
    }

    func setTooltip(_ text: String) {
        item.button?.toolTip = text
    }

    /// The menu bar indicator: the glyph breathes while a request is in flight. It is a Core
    /// Animation animation on the button's layer, so it costs the process nothing once started.
    func setWorking(_ working: Bool) {
        guard let layer = item.button?.layer else { return }
        if working {
            guard layer.animation(forKey: "working") == nil else { return }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.35
            pulse.duration = 0.62
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(pulse, forKey: "working")
        } else {
            layer.removeAnimation(forKey: "working")
            layer.opacity = 1
        }
    }

    func shutdown() {
        setWorking(false)
        NSStatusBar.system.removeStatusItem(item)
    }

    // ---- menu ----

    private func rebuildMenu(config: AppConfig, paused: Bool) {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        for (index, action) in config.actions.enumerated() {
            let entry = NSMenuItem(
                title: action.name, action: #selector(actionHint(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = index
            entry.isEnabled = action.enabled
            if let binding = HotkeyBinding.parse(action.hotkey), !binding.isEmpty {
                if let (key, mask) = StatusItem.menuKeyEquivalent(for: binding) {
                    // Rendered by AppKit in the native right-aligned style rather than glued onto
                    // the title. It is only a live key equivalent while this menu is open.
                    entry.keyEquivalent = key
                    entry.keyEquivalentModifierMask = mask
                } else {
                    entry.title = "\(action.name)   \(binding.display())"
                }
            }
            menu.addItem(entry)
        }

        menu.addItem(.separator())

        let pause = NSMenuItem(title: "Pause hotkeys", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        pause.state = paused ? .on : .off
        menu.addItem(pause)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        settings.keyEquivalentModifierMask = [.command]
        menu.addItem(settings)

        // The single most useful thing the menu can say when nothing is working. Always present so
        // menuWillOpen can reveal it without rebuilding the menu; hidden while the permission is
        // granted, which is almost always.
        let grant = NSMenuItem(
            title: "Grant Accessibility permission…", action: #selector(grantAccessibility), keyEquivalent: "")
        grant.target = self
        grant.isHidden = Permissions.isTrusted
        menu.addItem(grant)
        grantPermissionItem = grant

        let configFolder = NSMenuItem(
            title: "Open config folder", action: #selector(openConfigFolder), keyEquivalent: "")
        configFolder.target = self
        menu.addItem(configFolder)

        let log = NSMenuItem(title: "Open log", action: #selector(openLog), keyEquivalent: "")
        log.target = self
        menu.addItem(log)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit TextFix", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        quit.keyEquivalentModifierMask = [.command]
        menu.addItem(quit)

        item.menu = menu
    }

    /// Corrected as the menu opens so the Accessibility entry tracks the real permission state
    /// rather than whatever it was at launch. Only visibility changes here: replacing the menu
    /// while AppKit is opening it is a good way to get an empty one.
    func menuWillOpen(_ menu: NSMenu) {
        grantPermissionItem?.isHidden = Permissions.isTrusted
    }

    @objc private func actionHint(_ sender: NSMenuItem) {
        // Running an action from the menu would read the wrong window: opening the menu is itself a
        // focus change, so the capture would see the menu rather than the user's text box. Keep the
        // entry as a reminder of the hotkey instead of doing something surprising.
        onActionHint?(sender.tag)
    }

    @objc private func togglePause() { onTogglePause?() }
    @objc private func openSettings() { onSettings?() }
    @objc private func openConfigFolder() { onOpenConfigFolder?() }
    @objc private func openLog() { onOpenLog?() }
    @objc private func quit() { onQuit?() }

    @objc private func grantAccessibility() {
        Permissions.requestWithSystemPrompt()
        Permissions.openAccessibilitySettings()
    }

    // ---- key equivalents ----

    /// Translates a binding into the (character, modifier mask) pair AppKit draws next to a menu
    /// item. Returns nil for keys with no sensible character, and the caller then writes the
    /// combination into the title instead.
    static func menuKeyEquivalent(for binding: HotkeyBinding) -> (String, NSEvent.ModifierFlags)? {
        var mask: NSEvent.ModifierFlags = []
        if binding.modifiers & UInt32(controlKey) != 0 { mask.insert(.control) }
        if binding.modifiers & UInt32(optionKey) != 0 { mask.insert(.option) }
        if binding.modifiers & UInt32(shiftKey) != 0 { mask.insert(.shift) }
        if binding.modifiers & UInt32(cmdKey) != 0 { mask.insert(.command) }

        if let functionKey = functionKeyCharacters[Int(binding.keyCode)],
           let scalar = UnicodeScalar(UInt16(functionKey)) {
            return (String(scalar), mask)
        }
        let name = KeyNames.name(for: binding.keyCode)
        if name.count == 1, let character = name.lowercased().first, character.isASCII,
           character.isLetter || character.isNumber {
            return (String(character), mask)
        }
        return nil
    }

    private static let functionKeyCharacters: [Int: Int] = [
        kVK_F1: NSF1FunctionKey, kVK_F2: NSF2FunctionKey, kVK_F3: NSF3FunctionKey,
        kVK_F4: NSF4FunctionKey, kVK_F5: NSF5FunctionKey, kVK_F6: NSF6FunctionKey,
        kVK_F7: NSF7FunctionKey, kVK_F8: NSF8FunctionKey, kVK_F9: NSF9FunctionKey,
        kVK_F10: NSF10FunctionKey, kVK_F11: NSF11FunctionKey, kVK_F12: NSF12FunctionKey,
        kVK_F13: NSF13FunctionKey, kVK_F14: NSF14FunctionKey, kVK_F15: NSF15FunctionKey,
        kVK_F16: NSF16FunctionKey, kVK_F17: NSF17FunctionKey, kVK_F18: NSF18FunctionKey,
        kVK_F19: NSF19FunctionKey, kVK_F20: NSF20FunctionKey,
    ]
}
