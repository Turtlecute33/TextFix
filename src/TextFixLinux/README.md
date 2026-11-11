# TextFix for Linux

![TextFix Linux settings](../../docs/linux-settings.png)

Native C++ / Qt Quick agent for Hyprland (including Omarchy) and X11. Other Wayland
desktops use clipboard mode. Qt 6.4 or newer is required; Qt is supplied by your
distribution rather than bundled in the download.

## Install a release

Download `TextFix-linux-x64.zip` or `TextFix-linux-arm64.zip`, extract it and run
`./install.sh`. This installs into `~/.local`; add `~/.local/bin` to PATH if needed.
The Omarchy archives include Hyprland binding examples as well.

On Ubuntu 24.04 or newer, install the runtime dependencies:

```sh
sudo apt install libqt6quickcontrols2-6 libqt6svg6 qt6-wayland \
  qml6-module-qtquick qml6-module-qtquick-controls qml6-module-qtquick-layouts \
  qml6-module-qtquick-window qml6-module-qtqml-workerscript \
  qml6-module-qtquick-templates libsecret-tools wl-clipboard xdotool x11-utils
```

On Arch / Omarchy, install `qt6-base qt6-declarative qt6-svg qt6-wayland
wl-clipboard libsecret`. Install `xdotool xorg-xprop` as well for X11.
A running Secret Service provider, such as GNOME Keyring or KeePassXC with Secret
Service integration enabled, is needed to save keys. `TEXTFIX_API_KEY` is also
accepted, including for headless use. Keys never go in config.json.

Run `textfix settings`, enter your provider key and model, then save. Settings live
in `$XDG_CONFIG_HOME/textfix/config.json` (normally `~/.config/textfix/config.json`).
The provider, model, prompts and action settings use the Windows/macOS JSON names;
platform-specific clipboard, startup and shortcut options are separate.

## Desktop shortcuts

Bind `textfix fix` and `textfix rewrite` in your desktop shortcut settings. Commands
start the background agent on demand and forward subsequent requests to that one
process. A second invocation while busy cancels. Closing Settings hides the window;
the tray icon opens it again. Middle-clicking the tray cancels; `textfix quit` exits.
The tray requires a StatusNotifier host; the commands work without one.

| Shortcut | Action |
| --- | --- |
| Ctrl+Alt+J (example desktop binding) | Fix |
| Ctrl+Alt+K (example desktop binding) | Rewrite |
| Ctrl+S in Settings | Save |
| Escape in Settings | Hide |
| ? outside text inputs | Shortcut help |
| Q outside text inputs | Quit with confirmation |
| Ctrl+Z in the target app | Undo replacement |

For Omarchy, build and install a native Arch package from the repository root:

```sh
cd packaging/omarchy
makepkg -si
```

Or install an extracted `TextFix-omarchy-<arch>.zip` using its `install.sh`.
The app follows Omarchy's accent, background, foreground, window rounding and
language file live. English and Italian are bundled; other languages fall back
to English. Theme watching uses file notifications, with no idle polling.

Add the bindings explicitly after checking for existing conflicts:

```lua
-- ~/.config/hypr/bindings.lua, for a package installed into /usr:
dofile("/usr/share/textfix/omarchy/textfix.lua")
-- For a user installation, use ~/.local/share instead:
-- dofile(os.getenv("HOME") .. "/.local/share/textfix/omarchy/textfix.lua")
```

For older Hyprland configurations, source the adjacent `textfix.conf` instead.
Examples trigger on release so held modifiers do not interfere with copying.
Change the example chords to F13/F14 for a VIA/QMK keyboard. Installation does not
edit Hyprland files or claim keybindings automatically. The optional **Start TextFix
when I log in** setting uses the standard XDG autostart directory; on desktops
without XDG autostart, add `textfix --background` to the compositor's autostart.

## Desktop behavior and limits

Hyprland uses `hyprctl`'s native shortcut dispatcher (Lua and older configurations
are supported) and `wl-clipboard`; X11 uses `xdotool` and Qt's clipboard. No root
keyboard daemon or `/dev/uinput` access is needed. Keep TextFix in the same desktop
session as the target app.

With a selection, only that text is replaced. Otherwise Ctrl+A/C copies the whole
field when enabled. Common terminal classes use Ctrl+Shift+C/V and **require a
selection**; the agent never sends Ctrl+A to a detected terminal. Custom terminal
classes should use clipboard mode. Only trigger in a trusted editable field:
Linux does not provide a reliable cross-application password-field check.

The window identity is checked before each synthetic shortcut and before pasting.
Switching windows cancels replacement and keeps your clipboard safe. Moving the
caret or changing the selection inside the same window cannot be detected, so
leave the target untouched until the request finishes.

X11 restores all offered clipboard formats. Wayland restores **one representation**
(UTF-8/plain text preferred, then PNG, then the first offered type); rich text's
alternate formats are not retained. A clipboard with no readable offer may require
copying text once before direct replacement. Clipboard changes during a request or
the restore delay are respected. `wl-copy --sensitive` is used when available,
but clipboard managers can still record the target app's own Ctrl+C operation.

On GNOME Wayland, KDE Wayland and other compositors:

```sh
textfix clipboard             # copy first, run this, then paste yourself
textfix clipboard --rewrite
```

This mode never injects keys, leaves the result on the clipboard and refuses to
overwrite a clipboard that changed during the request. Desktop action commands
exit after submitting work; the agent reports completion/errors through desktop
notifications and Settings. Use `filter` for synchronous scripts and exit status.

OpenRouter zero data retention is enforced when enabled. Unlike the other agents,
Linux currently fails if no compatible route is available, without downgrading the
retention policy. Requests have a total deadline, bounded replies, limited retries,
no cookies and no redirects. Provider response bodies and user text are not logged.

## Build and test

Needs a C++17 compiler, make, qmake6, Qt 6 base/declarative/SVG development packages,
and zip. On Ubuntu add `qt6-base-dev qt6-declarative-dev qt6-svg-dev`; Arch includes
the development files in its Qt packages. No third-party source downloads are used.

```sh
./build-linux.sh --test --zip --version 1.4.0
./build-linux.sh --omarchy --zip --version 1.4.0
textfix doctor --json
printf 'rough text' | textfix filter
printf 'rough text' | textfix filter --rewrite --json
```

Filter and doctor run without a display. Filter exits 0 on success and 1 on errors;
`--json` returns `ok`, `text` and `error`. Doctor reports tools and direct-replacement
availability, with exit 1 when the desktop requires setup or clipboard mode.
Enable **Dry run** to test capture/replacement locally using uppercase text without
spending API credits. CI builds/tests x64 and arm64 on Ubuntu and builds an Omarchy
package on Arch. Tagged releases include Linux and Omarchy zip files, Arch packages,
checksums and GitHub build attestations.
