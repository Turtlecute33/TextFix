// SPDX-License-Identifier: GPL-3.0-only
import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

ApplicationWindow {
    id: win
    width: 660
    height: 770
    minimumWidth: 480
    minimumHeight: 480
    visible: false
    title: qsTr("TextFix Settings")
    color: theme.background
    Material.theme: Material.Dark
    Material.primary: theme.background
    Material.accent: theme.accent
    Material.foreground: theme.foreground
    // roundedScale was added after Qt 6.4, which Ubuntu 24.04 still ships.
    function updateCorners() { if (Material.hasOwnProperty("roundedScale")) Material.roundedScale = theme.radius }
    Component.onCompleted: updateCorners()
    Connections { target: theme; function onChanged() { win.updateCorners() } }
    onClosing: function(close) { close.accepted = false; win.hide() }
    footer: ToolBar {
        background: Rectangle { color: theme.background; border.color: "#333338" }
        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 12
            Label { text: backend.status; wrapMode: Text.WordWrap; Layout.fillWidth: true; color: theme.accent }
            RowLayout {
                Button { text: qsTr("Save"); enabled: !backend.busy; onClicked: win.save() }
                Button { text: qsTr("Cancel request"); enabled: backend.busy; onClicked: backend.cancel() }
                Button { text: qsTr("Help"); onClicked: help.open() }
                Button { text: qsTr("Quit"); onClicked: quitDialog.open() }
            }
        }
        implicitHeight: 110
    }
    property var draft: JSON.parse(JSON.stringify(backend.settings))
    property bool dirty: false
    function open() { theme.reload(); show(); raise(); requestActivate() }
    function save() {
        draft.provider = provider.currentIndex === 0 ? "openrouter" : "payperq"
        draft.model = model.text.trim()
        draft.dryRun = dryRun.checked
        draft.zeroDataRetention = retention.checked
        draft.restoreClipboard = restoreClipboard.checked
        draft.actions[0].wholeTextWhenNoSelection = wholeField.checked
        draft.actions[0].prompt = fixPrompt.text
        draft.actions[1].prompt = rewritePrompt.text
        if (backend.save(draft, apiKey.text, login.checked)) {
            apiKey.clear()
            dirty = false
        }
    }
    Shortcut { sequence: "Ctrl+S"; context: Qt.ApplicationShortcut; onActivated: win.save() }
    Shortcut { sequence: "Escape"; context: Qt.ApplicationShortcut; onActivated: win.hide() }
    Shortcut { sequence: "?"; context: Qt.ApplicationShortcut; enabled: !apiKey.activeFocus && !model.activeFocus && !fixPrompt.activeFocus && !rewritePrompt.activeFocus; onActivated: help.open() }
    Shortcut { sequence: "Q"; context: Qt.ApplicationShortcut; enabled: !apiKey.activeFocus && !model.activeFocus && !fixPrompt.activeFocus && !rewritePrompt.activeFocus; onActivated: quitDialog.open() }
    Item {
        anchors.fill: parent
        LayoutMirroring.enabled: Qt.application.layoutDirection === Qt.RightToLeft
        LayoutMirroring.childrenInherit: true
        ScrollView {
            anchors.fill: parent
            anchors.margins: 24
            contentWidth: availableWidth
            ColumnLayout {
                width: parent.width
                spacing: 14
                Label { text: "TextFix"; font.pixelSize: 32; font.bold: true }
                Label { text: qsTr("One shortcut. Your text, fixed in place."); wrapMode: Text.WordWrap; Layout.fillWidth: true }
                Label { text: backend.platform; color: theme.accent }
                Label { text: qsTr("Bind textfix fix and textfix rewrite in your desktop shortcuts. On other Wayland desktops, copy text and use textfix clipboard."); wrapMode: Text.WordWrap; Layout.fillWidth: true }
                ComboBox {
                    id: provider
                    model: ["OpenRouter", "PayPerQ"]
                    currentIndex: win.draft.provider === "payperq" ? 1 : 0
                    Layout.fillWidth: true
                    onActivated: win.dirty = true
                }
                TextField {
                    id: apiKey
                    placeholderText: qsTr("API key (leave blank to keep the saved key)")
                    echoMode: TextInput.Password
                    Layout.fillWidth: true
                    onTextEdited: win.dirty = true
                }
                Label { text: qsTr("Keys are stored in your Secret Service keyring."); wrapMode: Text.WordWrap; Layout.fillWidth: true; opacity: 0.7 }
                TextField {
                    id: model
                    placeholderText: qsTr("Model ID")
                    text: win.draft.model === "custom" ? win.draft.customModel : win.draft.model
                    Layout.fillWidth: true
                    onTextEdited: win.dirty = true
                }
                CheckBox { id: retention; text: qsTr("Require zero data retention on OpenRouter"); checked: win.draft.zeroDataRetention; onToggled: win.dirty = true }
                CheckBox { id: restoreClipboard; text: qsTr("Restore clipboard after replacing text"); checked: win.draft.restoreClipboard; onToggled: win.dirty = true }
                CheckBox { id: wholeField; text: qsTr("Fix the whole field when nothing is selected"); checked: win.draft.actions[0].wholeTextWhenNoSelection; onToggled: win.dirty = true }
                CheckBox { id: login; text: qsTr("Start TextFix when I log in"); checked: backend.autostart(); onToggled: win.dirty = true }
                CheckBox { id: dryRun; text: qsTr("Dry run: uppercase locally, without an API call"); checked: win.draft.dryRun; onToggled: win.dirty = true }
                CheckBox { id: promptsVisible; text: qsTr("Edit prompts") }
                GroupBox {
                    visible: promptsVisible.checked
                    title: qsTr("Prompts")
                    Layout.fillWidth: true
                    ColumnLayout {
                        anchors.fill: parent
                        Label { text: qsTr("Fix") }
                        TextArea { id: fixPrompt; text: win.draft.actions[0].prompt; wrapMode: TextEdit.Wrap; Layout.fillWidth: true; onTextChanged: if (activeFocus) win.dirty = true }
                        Label { text: qsTr("Rewrite") }
                        TextArea { id: rewritePrompt; text: win.draft.actions[1].prompt; wrapMode: TextEdit.Wrap; Layout.fillWidth: true; onTextChanged: if (activeFocus) win.dirty = true }
                    }
                }
                Label { text: qsTr("Select text in a trusted editable field before triggering a shortcut. Terminal windows require a selection. Clipboard history may retain copied text."); wrapMode: Text.WordWrap; Layout.fillWidth: true; opacity: 0.7 }
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
