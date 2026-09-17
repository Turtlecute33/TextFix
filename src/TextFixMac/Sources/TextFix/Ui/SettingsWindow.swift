// SPDX-License-Identifier: GPL-3.0-only
import AppKit

/// The settings window, built directly on AppKit controls so the resident process carries no UI
/// framework beyond the one every Mac app already links.
///
/// It exists only while open: closing it releases every control and the agent goes back to its menu
/// bar item and its hotkeys. The layout is three tabs of `label: control` rows, which is the shape a
/// Mac user already knows from every other preferences window - not a port of the Windows dialog's
/// single tall two-column grid, which at this many options would not fit on a laptop screen.
final class SettingsWindowController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private static let keyPlaceholder = "••••••••••••"
    private static let labelWidth: CGFloat = 118
    private static let windowWidth: CGFloat = 560
    private static let tabInset: CGFloat = 16
    private static let promptHeight: CGFloat = 88

    private let config: AppConfig
    private let onClosed: (AppConfig?) -> Void

    private var window: NSWindow?
    private var provider: AiProvider
    private var models: [ModelEntry] = []
    private var apiKeyDirty = false

    // Controls read back on save.
    private let providerPopUp = Controls.popUp([])
    private let apiKeyField = Controls.secureField(placeholder: "Paste your API key")
    private let modelPopUp = Controls.popUp([])
    private let customModelField = Controls.textField(placeholder: "author/model")
    private let zdrCheck = Controls.checkbox("Ask for zero-data-retention routing")
    private let reasoningCheck = Controls.checkbox("Let the model reason before answering (slower)")
    private let indicatorPopUp = Controls.popUp([])
    private let replaceModePopUp = Controls.popUp([])
    private let restorePasteboardCheck = Controls.checkbox("Put my clipboard back afterwards")
    private let notifyCheck = Controls.checkbox("Show failures on screen")
    private let loginItemCheck = Controls.checkbox("Start TextFix when I log in")
    private let accessibilityReadCheck = Controls.checkbox("Read text through the Accessibility API when possible")

    private var actionEnabled: [NSButton] = []
    private var actionHotkey: [HotkeyField] = []
    private var actionWholeField: [NSButton] = []
    private var actionPrompt: [NSTextView] = []
    private var actionBindings: [HotkeyBinding?] = []

    private var accessibilityBanner: NSView?

    init(config: AppConfig, onClosed: @escaping (AppConfig?) -> Void) {
        self.config = config.copy()
        self.onClosed = onClosed
        self.provider = self.config.providerValue
        super.init()
    }

    var isOpen: Bool { window != nil }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let root = buildRoot()
        let size = root.fittingSize
        root.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "TextFix Settings"
        window.contentView = root
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        loadValues()
        updateEnabledState()

        // An agent normally has no business stealing focus, but the user just asked for this
        // window, so it comes to the front like any other.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // Only when there is nothing there yet. A field holding a saved key, focused, is one stray
        // keystroke away from being saved as that keystroke.
        window.makeFirstResponder(SecretStore.hasApiKey(for: provider) ? modelPopUp : apiKeyField)
    }

    // ---- layout ----

    private func buildRoot() -> NSView {
        let contentWidth = Self.windowWidth - Self.tabInset * 2

        let providerTab = buildProviderTab(width: contentWidth)
        let behaviourTab = buildBehaviourTab(width: contentWidth)
        let actionsTab = buildActionsTab(width: contentWidth)

        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.tabViewType = .topTabsBezelBorder
        tabView.controlSize = .regular

        var tallest: CGFloat = 0
        for (label, stack) in [
            ("Provider", providerTab), ("Behaviour", behaviourTab), ("Hotkeys & Prompts", actionsTab),
        ] {
            let holder = NSView()
            holder.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: holder.topAnchor, constant: 16),
                stack.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 14),
                stack.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -14),
                stack.bottomAnchor.constraint(lessThanOrEqualTo: holder.bottomAnchor, constant: -16),
            ])
            let item = NSTabViewItem()
            item.label = label
            item.view = holder
            tabView.addTabViewItem(item)
            tallest = max(tallest, stack.fittingSize.height)
        }
        // The tab view sizes to the tallest page so switching tabs never resizes the window under
        // the user's hands, which is the thing that makes a tabbed preferences window feel cheap.
        tabView.heightAnchor.constraint(equalToConstant: tallest + 74).isActive = true

        let banner = buildAccessibilityBanner()
        accessibilityBanner = banner
        banner.isHidden = Permissions.isTrusted

        let column = NSStackView(views: [banner, tabView])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 12
        column.edgeInsets = NSEdgeInsets(top: 14, left: Self.tabInset, bottom: 0, right: Self.tabInset)
        column.translatesAutoresizingMaskIntoConstraints = false

        let footer = buildFooter()

        let root = NSView()
        root.addSubview(column)
        root.addSubview(footer)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.windowWidth),

            column.topAnchor.constraint(equalTo: root.topAnchor),
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            banner.widthAnchor.constraint(equalToConstant: contentWidth),
            tabView.widthAnchor.constraint(equalToConstant: contentWidth),

            footer.topAnchor.constraint(equalTo: column.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return root
    }

    private func column(width: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: width - 28).isActive = true
        return stack
    }

    private func buildProviderTab(width: CGFloat) -> NSStackView {
        let stack = column(width: width)

        providerPopUp.removeAllItems()
        providerPopUp.addItems(withTitles: AiProvider.allCases.map(\.displayName))
        providerPopUp.target = self
        providerPopUp.action = #selector(providerChanged)
        stack.addArrangedSubview(Controls.row("Provider", providerPopUp, labelWidth: Self.labelWidth))

        apiKeyField.delegate = self
        apiKeyField.widthAnchor.constraint(equalToConstant: 280).isActive = true
        let keyRow = NSStackView(views: [
            apiKeyField, Controls.link("Get a key ↗", target: self, action: #selector(openKeyPage)),
        ])
        keyRow.orientation = .horizontal
        keyRow.spacing = 8
        keyRow.alignment = .centerY
        keyRow.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(Controls.row("API key", keyRow, labelWidth: Self.labelWidth))
        stack.addArrangedSubview(indented(
            Controls.hint("Kept in your login keychain. It never goes into config.json.")))

        modelPopUp.target = self
        modelPopUp.action = #selector(modelChanged)
        stack.addArrangedSubview(Controls.row("Model", modelPopUp, labelWidth: Self.labelWidth))

        customModelField.widthAnchor.constraint(equalToConstant: 280).isActive = true
        stack.addArrangedSubview(Controls.row("Custom model", customModelField, labelWidth: Self.labelWidth))

        stack.addArrangedSubview(indented(zdrCheck))
        stack.addArrangedSubview(indented(reasoningCheck))
        return stack
    }

    private func buildBehaviourTab(width: CGFloat) -> NSStackView {
        let stack = column(width: width)

        indicatorPopUp.removeAllItems()
        indicatorPopUp.addItems(withTitles: [
            "Pulse below the caret", "Menu bar icon only", "Show nothing",
        ])
        stack.addArrangedSubview(Controls.row("While working", indicatorPopUp, labelWidth: Self.labelWidth))

        replaceModePopUp.removeAllItems()
        replaceModePopUp.addItems(withTitles: [
            "Pasting it — Cmd+Z undoes it", "Writing it directly — never touches the clipboard",
        ])
        replaceModePopUp.target = self
        replaceModePopUp.action = #selector(replaceModeChanged)
        stack.addArrangedSubview(Controls.row("Putting text back by", replaceModePopUp, labelWidth: Self.labelWidth))
        stack.addArrangedSubview(indented(Controls.hint(
            "Pasting goes through the app's own paste path, so one Cmd+Z puts your text back. "
            + "Writing directly is faster, but a lot of apps record nothing to undo.")))

        stack.addArrangedSubview(indented(restorePasteboardCheck))
        stack.addArrangedSubview(indented(accessibilityReadCheck))
        stack.addArrangedSubview(indented(notifyCheck))
        stack.addArrangedSubview(indented(loginItemCheck))
        return stack
    }

    private func buildActionsTab(width: CGFloat) -> NSStackView {
        let stack = column(width: width)

        for index in 0..<min(2, config.actions.count) {
            if index > 0 {
                let separator = Controls.separator()
                stack.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            buildActionSection(index: index, into: stack)
        }

        let footnote = Controls.hint(
            "With nothing selected TextFix fixes the whole field; with a selection it fixes just the "
            + "selection. F13-F20 make good hotkeys for a VIA or QMK keyboard — nothing on macOS "
            + "claims them, so they can never collide with an app shortcut.")
        stack.addArrangedSubview(footnote)
        footnote.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func buildActionSection(index: Int, into stack: NSStackView) {
        let action = config.actions[index]

        let enabled = Controls.checkbox("Enabled", target: self, action: #selector(actionEnabledChanged))
        enabled.tag = index
        actionEnabled.append(enabled)

        let header = NSStackView(views: [Controls.sectionHeader(action.name.uppercased()), enabled])
        header.orientation = .horizontal
        header.spacing = 14
        header.alignment = .centerY
        header.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(header)

        let hotkey = HotkeyField()
        hotkey.onChange = { [weak self] binding in self?.actionBindings[index] = binding }
        hotkey.onRejected = { [weak self] message in self?.complain(message) }
        actionHotkey.append(hotkey)
        actionBindings.append(HotkeyBinding.parse(action.hotkey))

        let whole = Controls.checkbox("Whole field when nothing is selected")
        actionWholeField.append(whole)

        let hotkeyRow = NSStackView(views: [hotkey, whole])
        hotkeyRow.orientation = .horizontal
        hotkeyRow.spacing = 12
        hotkeyRow.alignment = .centerY
        hotkeyRow.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(Controls.row("Hotkey", hotkeyRow, labelWidth: Self.labelWidth))

        let (scroll, text) = Controls.promptEditor()
        actionPrompt.append(text)
        scroll.heightAnchor.constraint(equalToConstant: Self.promptHeight).isActive = true
        let promptRow = Controls.row("Prompt", scroll, labelWidth: Self.labelWidth, alignTop: true)
        stack.addArrangedSubview(promptRow)
        promptRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.trailingAnchor.constraint(equalTo: promptRow.trailingAnchor).isActive = true
    }

    private func buildAccessibilityBanner() -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.14).cgColor
        box.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        icon.contentTintColor = .systemOrange
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let title = Controls.label(
            "Accessibility permission needed", font: .systemFont(ofSize: 12, weight: .semibold))
        let body = Controls.hint(
            "macOS only lets TextFix read and replace text in other apps once you allow it.")
        let open = Controls.button(
            "Open System Settings", target: self, action: #selector(openAccessibilitySettings))
        open.controlSize = .small
        open.setContentHuggingPriority(.required, for: .horizontal)
        open.setContentCompressionResistancePriority(.required, for: .horizontal)

        let text = NSStackView(views: [title, body])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.translatesAutoresizingMaskIntoConstraints = false

        box.addSubview(icon)
        box.addSubview(text)
        box.addSubview(open)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            icon.topAnchor.constraint(equalTo: box.topAnchor, constant: 11),

            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            text.topAnchor.constraint(equalTo: box.topAnchor, constant: 9),
            text.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -9),
            text.trailingAnchor.constraint(lessThanOrEqualTo: open.leadingAnchor, constant: -10),

            open.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            open.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        return box
    }

    private func buildFooter() -> NSView {
        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false

        let cancel = Controls.button("Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}" // Esc
        let save = Controls.button("Save", target: self, action: #selector(saveClicked), isDefault: true)

        footer.addSubview(cancel)
        footer.addSubview(save)
        NSLayoutConstraint.activate([
            save.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -Self.tabInset),
            save.topAnchor.constraint(equalTo: footer.topAnchor, constant: 14),
            save.bottomAnchor.constraint(equalTo: footer.bottomAnchor, constant: -16),
            save.widthAnchor.constraint(greaterThanOrEqualToConstant: 84),

            cancel.trailingAnchor.constraint(equalTo: save.leadingAnchor, constant: -10),
            cancel.centerYAnchor.constraint(equalTo: save.centerYAnchor),
            cancel.widthAnchor.constraint(greaterThanOrEqualToConstant: 84),
        ])
        return footer
    }

    /// Lines a control up with the control column, for the checkboxes and hints that have no
    /// caption of their own.
    private func indented(_ view: NSView) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.labelWidth + 10),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    // ---- values ----

    private func loadValues() {
        providerPopUp.selectItem(at: provider == .payPerQ ? 1 : 0)
        populateModels()

        apiKeyField.stringValue = SecretStore.hasApiKey(for: provider) ? Self.keyPlaceholder : ""
        apiKeyDirty = false
        customModelField.stringValue = config.customModel

        zdrCheck.state = config.zeroDataRetention ? .on : .off
        reasoningCheck.state = config.allowReasoning ? .on : .off
        restorePasteboardCheck.state = config.restorePasteboard ? .on : .off
        accessibilityReadCheck.state = config.useAccessibilityRead ? .on : .off
        notifyCheck.state = config.notifyOnError ? .on : .off
        loginItemCheck.state = LoginItem.isEnabled ? .on : .off

        indicatorPopUp.selectItem(at: {
            switch config.indicatorValue {
            case .caret: return 0
            case .menubar: return 1
            case .none: return 2
            }
        }())
        replaceModePopUp.selectItem(at: config.replaceModeValue == .accessibility ? 1 : 0)

        for index in 0..<actionEnabled.count {
            let action = config.actions[index]
            actionEnabled[index].state = action.enabled ? .on : .off
            actionWholeField[index].state = action.wholeTextWhenNoSelection ? .on : .off
            actionPrompt[index].string = action.prompt
            actionHotkey[index].binding = actionBindings[index]
        }
    }

    private func populateModels() {
        modelPopUp.removeAllItems()
        models = ModelCatalog.entries(for: provider)
        var selectedIndex = -1
        for (index, entry) in models.enumerated() {
            var label = "\(entry.displayName)  —  \(entry.tier.label)"
            if entry.zdr { label += ", ZDR" }
            if entry.cache { label += ", cached" }
            modelPopUp.addItem(withTitle: label)
            if entry.slug == config.model { selectedIndex = index }
        }
        modelPopUp.addItem(withTitle: "Custom model slug…")
        if config.model == ModelCatalog.customSlug { selectedIndex = models.count }
        // A model saved for the other provider is not silently kept: falling back to the first
        // entry is the same behaviour the Windows agent has when you switch providers.
        modelPopUp.selectItem(at: selectedIndex >= 0 ? selectedIndex : 0)
    }

    private func updateEnabledState() {
        customModelField.isEnabled = modelPopUp.indexOfSelectedItem == models.count
        // Zero data retention is an OpenRouter routing preference; on PayPerQ it is a property of
        // the model you pick, so the checkbox would promise something it cannot deliver.
        zdrCheck.isEnabled = provider == .openRouter
        // The clipboard is only borrowed by the paste path.
        restorePasteboardCheck.isEnabled = replaceModePopUp.indexOfSelectedItem == 0

        for index in 0..<actionEnabled.count {
            let on = actionEnabled[index].state == .on
            actionWholeField[index].isEnabled = on
            actionPrompt[index].isEditable = on
            actionPrompt[index].textColor = on ? .textColor : .disabledControlTextColor
        }
    }

    // ---- actions ----

    @objc private func providerChanged() {
        provider = providerPopUp.indexOfSelectedItem == 1 ? .payPerQ : .openRouter
        // Each provider has its own key and its own model namespace, so both fields follow the
        // selection instead of carrying a value that would fail on the new provider.
        apiKeyField.stringValue = SecretStore.hasApiKey(for: provider) ? Self.keyPlaceholder : ""
        apiKeyDirty = false
        if !ModelCatalog.supports(provider, config.model) {
            config.model = ModelCatalog.entries(for: provider)[0].slug
        }
        populateModels()
        updateEnabledState()
    }

    @objc private func modelChanged() {
        let index = modelPopUp.indexOfSelectedItem
        config.model = index >= 0 && index < models.count ? models[index].slug : ModelCatalog.customSlug
        updateEnabledState()
        if config.model == ModelCatalog.customSlug { window?.makeFirstResponder(customModelField) }
    }

    @objc private func replaceModeChanged() { updateEnabledState() }

    @objc private func actionEnabledChanged() { updateEnabledState() }

    @objc private func openKeyPage() { NSWorkspace.shared.open(provider.keyPageURL) }

    @objc private func openAccessibilitySettings() {
        Permissions.requestWithSystemPrompt()
        Permissions.openAccessibilitySettings()
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as AnyObject? === apiKeyField { apiKeyDirty = true }
    }

    @objc private func cancelClicked() { close(with: nil) }

    @objc private func saveClicked() {
        guard let collected = collect() else { return }
        close(with: collected)
    }

    // ---- collect ----

    private func collect() -> AppConfig? {
        let result = config

        result.provider = provider.pref
        let modelIndex = modelPopUp.indexOfSelectedItem
        result.model = modelIndex >= 0 && modelIndex < models.count
            ? models[modelIndex].slug
            : ModelCatalog.customSlug
        result.customModel = customModelField.stringValue.trimmingCharacters(in: .whitespaces)

        if result.model == ModelCatalog.customSlug {
            guard ModelCatalog.isValidCustomSlug(result.customModel) else {
                complain("That does not look like a model slug. Use author/model, for example openai/gpt-4o-mini.")
                return nil
            }
            guard !result.customModel.isEmpty else {
                complain("Enter a custom model slug, or pick one from the list.")
                return nil
            }
        }

        result.zeroDataRetention = zdrCheck.state == .on
        result.allowReasoning = reasoningCheck.state == .on
        result.restorePasteboard = restorePasteboardCheck.state == .on
        result.useAccessibilityRead = accessibilityReadCheck.state == .on
        result.notifyOnError = notifyCheck.state == .on
        result.indicator = {
            switch indicatorPopUp.indexOfSelectedItem {
            case 1: return IndicatorStyle.menubar.rawValue
            case 2: return IndicatorStyle.none.rawValue
            default: return IndicatorStyle.caret.rawValue
            }
        }()
        result.replaceMode = replaceModePopUp.indexOfSelectedItem == 1
            ? ReplaceMode.accessibility.rawValue
            : ReplaceMode.paste.rawValue

        for index in 0..<actionEnabled.count {
            let action = result.actions[index]
            action.enabled = actionEnabled[index].state == .on
            action.wholeTextWhenNoSelection = actionWholeField[index].state == .on
            let prompt = actionPrompt[index].string.trimmingCharacters(in: .whitespacesAndNewlines)
            action.prompt = prompt.isEmpty ? (index == 0 ? Defaults.fixPrompt : Defaults.rewritePrompt) : prompt

            let binding = actionBindings[index]
            if action.enabled, binding == nil || binding!.isEmpty {
                complain("Give \(action.name) a hotkey, or turn it off.")
                return nil
            }
            action.hotkey = binding?.format() ?? ""
        }

        if result.actions.count >= 2,
           result.actions[0].enabled, result.actions[1].enabled,
           !result.actions[0].hotkey.isEmpty,
           result.actions[0].hotkey.caseInsensitiveCompare(result.actions[1].hotkey) == .orderedSame {
            complain("Both actions are on \(result.actions[0].hotkey). Give them different hotkeys.")
            return nil
        }

        // The API key goes straight to the keychain rather than into the config object, so it never
        // passes through config.json.
        if apiKeyDirty {
            let typed = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if typed == Self.keyPlaceholder {
                // Untouched.
            } else if typed.isEmpty {
                SecretStore.setApiKey("", for: provider) // an emptied field removes the key
            } else if !Self.looksLikeApiKey(typed) {
                complain(
                    "That does not look like an API key. Paste the whole key, or clear the field"
                    + " to remove the one you have.")
                return nil
            } else {
                SecretStore.setApiKey(typed, for: provider)
            }
        }

        let wantsLoginItem = loginItemCheck.state == .on
        if wantsLoginItem != LoginItem.isEnabled, let problem = LoginItem.setEnabled(wantsLoginItem) {
            complain(problem)
            return nil
        }

        return result
    }

    /// Deliberately a shape check, not a format check: both providers issue keys in their own
    /// shapes and a third could change tomorrow. All this has to catch is the accident - a field
    /// that was showing a saved key and now holds one or two characters.
    private static func looksLikeApiKey(_ value: String) -> Bool {
        value.count >= 16 && !value.contains(where: \.isWhitespace)
    }

    private func complain(_ message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "TextFix settings"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    // ---- lifecycle ----

    private func close(with result: AppConfig?) {
        let window = self.window
        self.window = nil
        window?.delegate = nil
        window?.orderOut(nil)
        onClosed(result)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close(with: nil)
        return false
    }

    /// The user may have granted Accessibility while this window was open - in System Settings, in
    /// another app - so the banner is re-checked every time the window comes back to the front
    /// rather than only when it was built.
    func windowDidBecomeKey(_ notification: Notification) {
        let trusted = Permissions.isTrusted
        guard accessibilityBanner?.isHidden != trusted else { return }
        accessibilityBanner?.isHidden = trusted
        // The banner is an arranged subview, so hiding it collapses the stack - and the window is
        // not resizable, so without this the layout would be left fighting a height that no longer
        // matches its contents.
        resizeToFit()
    }

    private func resizeToFit() {
        guard let window, let root = window.contentView else { return }
        root.layoutSubtreeIfNeeded()
        let size = root.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        window.setContentSize(size)
    }
}
