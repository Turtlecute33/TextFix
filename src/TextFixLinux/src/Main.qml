// SPDX-License-Identifier: GPL-3.0-only
import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

ApplicationWindow {
    id: win
    width: 660
    height: 780
    minimumWidth: 480
    minimumHeight: 480
    visible: false
    title: qsTr("TextFix Settings")
    color: theme.background
    readonly property color ink: theme.foreground
    readonly property color hairline: Qt.rgba(ink.r, ink.g, ink.b, 0.18)
    Material.theme: theme.dark ? Material.Dark : Material.Light
    Material.primary: theme.background
    Material.background: theme.background
    Material.accent: theme.accent
    Material.foreground: theme.foreground
    // roundedScale was added after Qt 6.4, which Ubuntu 24.04 still ships.
    function updateCorners() { if (Material.hasOwnProperty("roundedScale")) Material.roundedScale = theme.radius }
    Component.onCompleted: { updateCorners(); load() }
    Connections { target: theme; function onChanged() { win.updateCorners() } }
    Connections { target: backend; function onSettingsChanged() { if (!win.dirty) win.load() } }
    onClosing: function(close) { close.accepted = false; win.hide() }

    property bool dirty: false
    property var modelList: []
    readonly property string providerSlug: provider.currentIndex === 1 ? "payperq" : "openrouter"
    readonly property bool typing: activeFocusItem instanceof TextInput || activeFocusItem instanceof TextEdit

    // Shows the list of the provider and selects the slug. A slug that the list does not have
    // goes to the custom field, so a model typed by hand is not lost.
    function showModels(slug, customSlug) {
        modelList = backend.models(providerSlug)
        var labels = []
        var index = -1
        for (var i = 0; i < modelList.length; ++i) {
            labels.push(modelList[i].label)
            if (modelList[i].slug === slug) index = i
        }
        labels.push(qsTr("Custom model slug…"))
        modelBox.model = labels
        if (index < 0 && slug !== "custom" && slug !== "") customSlug = slug
        custom.text = customSlug
        modelBox.currentIndex = index >= 0 ? index : slug === "" ? 0 : modelList.length
    }
    function selectedSlug() { return modelBox.currentIndex < modelList.length ? modelList[modelBox.currentIndex].slug : "custom" }
    function load() {
        var s = backend.settings
        provider.currentIndex = s.provider === "payperq" ? 1 : 0
        showModels(s.model, s.customModel)
        retention.checked = s.zeroDataRetention
        reasoning.checked = s.allowReasoning
        progress.checked = s.indicator !== "none"
        failures.checked = s.notifyOnError
        restoreClipboard.checked = s.restoreClipboard
        login.checked = backend.autostart()
        dryRun.checked = s.dryRun
        fixWhole.checked = s.actions[0].wholeTextWhenNoSelection
        fixPrompt.text = s.actions[0].prompt
        rewriteWhole.checked = s.actions[1].wholeTextWhenNoSelection
        rewritePrompt.text = s.actions[1].prompt
        apiKey.clear()
        dirty = false
    }
    function open() { theme.reload(); if (!dirty) load(); show(); raise(); requestActivate() }
    function save() {
        // Start from the saved settings, so that the keys this window does not show stay.
        var next = JSON.parse(JSON.stringify(backend.settings))
        next.provider = providerSlug
        next.model = selectedSlug()
        next.customModel = custom.text.trim()
        next.zeroDataRetention = retention.checked
        next.allowReasoning = reasoning.checked
        next.indicator = progress.checked ? "notification" : "none"
        next.notifyOnError = failures.checked
        next.restoreClipboard = restoreClipboard.checked
        next.dryRun = dryRun.checked
        next.actions[0].wholeTextWhenNoSelection = fixWhole.checked
        next.actions[0].prompt = fixPrompt.text
        next.actions[1].wholeTextWhenNoSelection = rewriteWhole.checked
        next.actions[1].prompt = rewritePrompt.text
        if (backend.save(next, apiKey.text, login.checked)) {
            apiKey.clear()
            dirty = false
        }
    }
    Shortcut { sequence: "Ctrl+S"; context: Qt.ApplicationShortcut; onActivated: win.save() }
    Shortcut { sequence: "Escape"; context: Qt.ApplicationShortcut; enabled: !help.visible && !quitDialog.visible; onActivated: win.hide() }
    Shortcut { sequence: "?"; context: Qt.ApplicationShortcut; enabled: !win.typing; onActivated: help.open() }
    Shortcut { sequence: "Q"; context: Qt.ApplicationShortcut; enabled: !win.typing; onActivated: quitDialog.open() }

    component Hint: Label { wrapMode: Text.WordWrap; Layout.fillWidth: true; opacity: 0.7 }
    component Heading: Label { font.bold: true; Layout.topMargin: 8 }

    header: ColumnLayout {
        spacing: 0
        RowLayout {
            Layout.margins: 24
            Layout.bottomMargin: 8
            spacing: 12
            Label { text: "TextFix"; font.pixelSize: 26; font.bold: true }
            Label { text: backend.platform; color: theme.accent; Layout.alignment: Qt.AlignBaseline }
        }
        TabBar {
            id: tabs
            objectName: "tabs"
            Layout.fillWidth: true
            TabButton { text: qsTr("Provider") }
            TabButton { text: qsTr("Behaviour") }
            TabButton { text: qsTr("Prompts") }
        }
    }
    footer: ToolBar {
        background: Rectangle { color: theme.background; border.color: win.hairline }
        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 12
            Label { text: backend.status; wrapMode: Text.WordWrap; Layout.fillWidth: true; color: theme.accent }
            RowLayout {
                Button { text: qsTr("Save"); highlighted: win.dirty; enabled: !backend.busy; onClicked: win.save() }
                Button { text: qsTr("Cancel request"); enabled: backend.busy; onClicked: backend.cancel() }
                Item { Layout.fillWidth: true }
                Button { text: qsTr("Help"); flat: true; onClicked: help.open() }
                Button { text: qsTr("Quit"); flat: true; onClicked: quitDialog.open() }
            }
        }
        implicitHeight: 110
    }
    StackLayout {
        anchors.fill: parent
        currentIndex: tabs.currentIndex
        LayoutMirroring.enabled: Qt.application.layoutDirection === Qt.RightToLeft
        LayoutMirroring.childrenInherit: true

        ScrollView {
            padding: 24
            contentWidth: availableWidth
            ColumnLayout {
                width: parent.width
                spacing: 12
                ComboBox {
                    id: provider
                    model: ["OpenRouter", "PayPerQ"]
                    Layout.fillWidth: true
                    Accessible.name: qsTr("Provider")
                    onActivated: { win.showModels(win.selectedSlug(), custom.text); win.dirty = true }
                }
                RowLayout {
                    spacing: 12
                    TextField {
                        id: apiKey
                        placeholderText: qsTr("API key (leave blank to keep the saved key)")
                        echoMode: TextInput.Password
                        Layout.fillWidth: true
                        Accessible.name: qsTr("API key")
                        onTextEdited: win.dirty = true
                    }
                    Button {
                        text: qsTr("Get a key")
                        flat: true
                        onClicked: Qt.openUrlExternally(win.providerSlug === "payperq" ? "https://ppq.ai/api-keys" : "https://openrouter.ai/keys")
                    }
                }
                Hint { text: qsTr("Kept in your Secret Service keyring. It never goes into config.json.") }
                Heading { text: qsTr("Model") }
                ComboBox {
                    id: modelBox
                    Layout.fillWidth: true
                    Accessible.name: qsTr("Model")
                    onActivated: win.dirty = true
                }
                TextField {
                    id: custom
                    visible: modelBox.currentIndex >= win.modelList.length
                    placeholderText: qsTr("Custom model slug, for example openai/gpt-4o-mini")
                    Layout.fillWidth: true
                    Accessible.name: qsTr("Custom model slug")
                    onTextEdited: win.dirty = true
                }
                CheckBox {
                    id: retention
                    text: qsTr("Ask for zero-data-retention routing")
                    enabled: win.providerSlug === "openrouter"
                    onToggled: win.dirty = true
                }
                CheckBox {
                    id: reasoning
                    text: qsTr("Let the model reason before answering (slower)")
                    enabled: win.providerSlug === "openrouter"
                    onToggled: win.dirty = true
                }
                Hint { text: qsTr("With zero data retention on, TextFix never uses a provider that keeps your text for training. PayPerQ has no switch for these two options.") }
            }
        }

        ScrollView {
            padding: 24
            contentWidth: availableWidth
            ColumnLayout {
                width: parent.width
                spacing: 4
                CheckBox { id: progress; text: qsTr("Show a notification while a fix runs"); onToggled: win.dirty = true }
                CheckBox { id: failures; text: qsTr("Show failures on screen"); onToggled: win.dirty = true }
                CheckBox { id: restoreClipboard; text: qsTr("Put my clipboard back afterwards"); onToggled: win.dirty = true }
                CheckBox { id: login; text: qsTr("Start TextFix when I log in"); onToggled: win.dirty = true }
                CheckBox { id: dryRun; text: qsTr("Dry run: make the text upper case and send nothing"); onToggled: win.dirty = true }
                Hint {
                    Layout.topMargin: 12
                    text: qsTr("Use TextFix only in a text field that you trust. Linux cannot tell TextFix that a field holds a password. A clipboard manager can keep the text that the app copies.")
                }
            }
        }

        ScrollView {
            padding: 24
            contentWidth: availableWidth
            ColumnLayout {
                width: parent.width
                spacing: 8
                Hint { text: qsTr("Bind textfix fix and textfix rewrite in your desktop shortcuts. On other Wayland desktops, copy text and use textfix clipboard.") }
                Heading { text: qsTr("Fix") }
                CheckBox { id: fixWhole; text: qsTr("Whole field when nothing is selected"); onToggled: win.dirty = true }
                TextArea {
                    id: fixPrompt
                    wrapMode: TextEdit.Wrap
                    Layout.fillWidth: true
                    Accessible.name: qsTr("Fix prompt")
                    onTextChanged: if (activeFocus) win.dirty = true
                }
                Button {
                    text: qsTr("Restore the default prompt")
                    flat: true
                    enabled: fixPrompt.text !== backend.defaultPrompt(0)
                    onClicked: { fixPrompt.text = backend.defaultPrompt(0); win.dirty = true }
                }
                Heading { text: qsTr("Rewrite") }
                CheckBox { id: rewriteWhole; text: qsTr("Whole field when nothing is selected"); onToggled: win.dirty = true }
                TextArea {
                    id: rewritePrompt
                    wrapMode: TextEdit.Wrap
                    Layout.fillWidth: true
                    Accessible.name: qsTr("Rewrite prompt")
                    onTextChanged: if (activeFocus) win.dirty = true
                }
                Button {
                    text: qsTr("Restore the default prompt")
                    flat: true
                    enabled: rewritePrompt.text !== backend.defaultPrompt(1)
                    onClicked: { rewritePrompt.text = backend.defaultPrompt(1); win.dirty = true }
                }
                Hint { text: qsTr("{text} is where your text goes. {nonce} makes a tag that the text cannot close.") }
            }
        }
    }
    Dialog {
        id: help
        title: qsTr("Shortcuts")
        anchors.centerIn: parent
        width: Math.min(440, win.width - 40)
        modal: true
        standardButtons: Dialog.Ok
        Label { width: parent.width; wrapMode: Text.WordWrap; text: qsTr("Ctrl+S: save settings\nEscape: hide settings\n?: show shortcuts\nQ: quit\n\nRun the same desktop shortcut again to cancel a request. Ctrl+Z in the original app undoes a replacement.") }
    }
    Dialog {
        id: quitDialog
        title: qsTr("Quit TextFix?")
        anchors.centerIn: parent
        modal: true
        standardButtons: Dialog.Yes | Dialog.No
        Label { text: win.dirty ? qsTr("Unsaved settings will be discarded.") : qsTr("Desktop shortcuts will restart TextFix when needed.") }
        onAccepted: Qt.quit()
    }
}
