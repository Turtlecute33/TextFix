// SPDX-License-Identifier: GPL-3.0-only
import AppKit

/// The resident half of the app: it owns the menu bar item, the global hotkeys and the settings
/// window, and does nothing whatsoever until a hotkey is pressed.
///
/// There is no window at launch, no Dock icon and no main menu on screen - the activation policy is
/// `.accessory`. The menu that *is* built below exists only so the standard editing shortcuts work
/// inside the settings window; without a main menu, Cmd+V in a text field does nothing, which is a
/// memorable way to discover how much AppKit routes through the menu bar.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let showSettingsNotification = Notification.Name("com.turtlecute33.textfix.showSettings")

    private var config = AppConfig()
    private var statusItem: StatusItem?
    private var fixService: FixService?
    private let hotkeys = HotkeyManager()
    private var settings: SettingsWindowController?
    private var paused = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        config = AppConfig.load()
        Log.verbose = config.verboseLog

        buildMainMenu()

        let statusItem = StatusItem(config: config)
        self.statusItem = statusItem
        wireStatusItem(statusItem)

        fixService = FixService(config: { [weak self] in self?.config ?? AppConfig() }, statusItem: statusItem)

        hotkeys.install { [weak self] index in
            self?.onHotkey(index)
        }

        // A second launch - from Spotlight, from the Finder - brings up the settings of the copy
        // that is already running instead of fighting it for the hotkeys.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(openSettings),
            name: AppDelegate.showSettingsNotification,
            object: nil)

        applyConfig()
        Log.info("Agent started")

        if config.wasCreatedFresh {
            // First run: an agent with no API key can do nothing, so say so up front rather than
            // waiting for the user to press a hotkey and get an error.
            openSettings()
            if !Permissions.isTrusted { Permissions.requestWithSystemPrompt() }
        } else if SecretStore.hasApiKey(for: config.providerValue) {
            // Warms the TLS session so the first fix of the session is as fast as the second.
            AiClient.prewarm(config.providerValue)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys.uninstall()
        fixService?.shutdown()
        CaretPulse.shared.shutdown()
        Toast.shared.shutdown()
        statusItem?.shutdown()
        DistributedNotificationCenter.default().removeObserver(self)
        Log.info("Agent stopped")
    }

    /// Nothing can close the agent by accident: the settings window closing is not the app quitting.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // ---- wiring ----

    private func wireStatusItem(_ statusItem: StatusItem) {
        statusItem.onSettings = { [weak self] in self?.openSettings() }
        statusItem.onTogglePause = { [weak self] in self?.togglePause() }
        statusItem.onOpenConfigFolder = {
            NSWorkspace.shared.open(AppConfig.directory)
        }
        statusItem.onOpenLog = {
            let manager = FileManager.default
            if manager.fileExists(atPath: Log.fileURL.path) {
                NSWorkspace.shared.open(Log.fileURL)
            } else {
                NSWorkspace.shared.open(Log.directory)
            }
        }
        statusItem.onQuit = { NSApp.terminate(nil) }
        statusItem.onActionHint = { [weak self] index in
            guard let self, index < self.config.actions.count else { return }
            let action = self.config.actions[index]
            let binding = HotkeyBinding.parse(action.hotkey)
            let hint = (binding?.isEmpty ?? true)
                ? "Assign a hotkey for \(action.name) in settings."
                : "Press \(binding!.display()) while your text box has focus."
            Toast.shared.show(title: action.name, message: hint, isError: false)
        }
    }

    private func onHotkey(_ index: Int) {
        fixService?.start(actionIndex: index)
    }

    private func togglePause() {
        paused.toggle()
        applyConfig()
    }

    private func applyConfig() {
        Log.verbose = config.verboseLog
        Keystrokes.keyEventDelayMs = config.keyEventDelayMs
        registerHotkeys()
        statusItem?.update(config: config, paused: paused)
    }

    private func registerHotkeys() {
        hotkeys.unregisterAll()
        guard !paused else { return }

        var bindings: [(index: Int, binding: HotkeyBinding)] = []
        for (index, action) in config.actions.enumerated() where action.enabled {
            guard let binding = HotkeyBinding.parse(action.hotkey), !binding.isEmpty else {
                if !action.hotkey.trimmingCharacters(in: .whitespaces).isEmpty {
                    Log.warn("Could not understand the hotkey for \(action.name): \(action.hotkey)")
                }
                continue
            }
            bindings.append((index, binding))
        }

        let failed = hotkeys.register(bindings)
        if !failed.isEmpty {
            let names = failed.compactMap { index -> String? in
                guard index < config.actions.count else { return nil }
                let action = config.actions[index]
                let binding = HotkeyBinding.parse(action.hotkey)
                return "\(action.name) (\(binding?.display() ?? action.hotkey))"
            }
            Toast.shared.show(
                title: "Hotkey unavailable",
                message: "Another app already owns: \(names.joined(separator: ", "))",
                isError: true)
        }
    }

    // ---- settings ----

    @objc func openSettings() {
        if let settings, settings.isOpen {
            settings.show()
            return
        }
        // A registered hotkey never reaches a window, so the recorder could not capture the
        // combination the user is already using. Release them while the window is open.
        hotkeys.unregisterAll()

        settings = SettingsWindowController(config: config) { [weak self] saved in
            guard let self else { return }
            self.settings = nil
            if let saved {
                saved.normalize()
                self.config = saved
                self.config.save()
                Log.info("Settings saved")
            }
            self.applyConfig()
        }
        settings?.show()
    }

    // ---- main menu ----

    /// The minimum menu an accessory app needs: an app menu so Cmd+Q works from anywhere, and an
    /// Edit menu so the text fields in the settings window get undo, cut, copy, paste and select
    /// all. AppKit routes all of those through the menu bar, so without this they simply do not
    /// work - and none of it is ever visible, because the app never activates as a foreground app
    /// with its own menu bar except while the settings window is open.
    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
            .target = self
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Hide TextFix", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit TextFix", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }
}
