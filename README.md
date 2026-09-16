<div align="center">

# TextFix

### One keyboard shortcut. Your text, fixed in place.

Press your hotkey in any text box, on Windows or macOS. With text selected it fixes the selection;
with nothing selected it fixes the whole field. The result replaces what was there, and one undo
puts it back.

Bring your own [OpenRouter](https://openrouter.ai/) or [PayPerQ](https://ppq.ai/) key. No account,
no subscription, no telemetry.

</div>

<br>

## What it is

Two small native agents that behave the same way and share one config format. Neither carries a UI
framework, a runtime or a single third-party dependency.

|  | Windows | macOS |
| --- | --- | --- |
| Lives in | the notification area | the menu bar, never the Dock |
| Built from | C# on direct Win32, Native AOT | Swift on AppKit |
| Ships as | one 6 MB `TextFix.exe` | a 1 MB universal `TextFix.app` |
| Needs | nothing | Accessibility permission |
| Reads your text by | clipboard round trip | the Accessibility API, clipboard as fallback |

Each sits idle using a few megabytes of private memory, burns no measurable CPU, and does nothing
whatsoever until you press the hotkey.

```
hotkey  in a text box, nothing selected  ->  the whole field comes back fixed
hotkey  with text selected               ->  only the selection comes back fixed
```

Two actions ship configured, each with its own hotkey and its own editable prompt:

- **Fix** - rebuilds rough dictation into clean writing: mistranscribed words, mangled sentences,
  missing punctuation, repetition. Keeps your meaning, points and tone, and never translates.
- **Rewrite** - clearer and more concise, same meaning.

<br>

## Install

### Windows

1. Download `TextFix-win-x64.zip` from the
   [latest release](https://github.com/Turtlecute33/TextFix/releases/latest) and unzip it, or build
   it yourself with `.\build.ps1`. Put `TextFix.exe` wherever you keep small tools;
   `%LOCALAPPDATA%\Programs\TextFix\` is a good spot.
2. Run it. The settings window opens on first launch and the tray icon appears.
3. Paste your API key, pick a model, press the hotkey you want into the capture box, tick **Start
   TextFix when I sign in**, and save.

Your key is encrypted with DPAPI under your Windows account in `%APPDATA%\TextFix\secrets.dat`. It
never goes into `config.json`.

### macOS

Needs macOS 13 Ventura or later. The download is one universal app for Apple Silicon and Intel.

1. Download `TextFix-macos-universal.zip` from the
   [latest release](https://github.com/Turtlecute33/TextFix/releases/latest), unzip it and drag
   `TextFix.app` into **Applications**. Or build it yourself with `./build-mac.sh`.
2. **The first launch needs a right-click > Open**, then *Open* again in the dialog. The app is
   signed, but ad-hoc rather than with a paid Apple Developer ID, so Gatekeeper wants you to say
   you meant it. Once is enough.
3. Allow it under **System Settings > Privacy & Security > Accessibility**. TextFix asks on first
   run and the settings window keeps a banner up until you do. Without it macOS lets no app read or
   replace text in another app's window, so nothing can work until this is on.
4. The settings window opens on first launch and the menu bar icon appears. Paste your API key, pick
   a model, click the hotkey field and press the keys you want, tick **Start TextFix when I log in**,
   and save.

Your key goes in the login keychain, not in `config.json`. Moving `TextFix.app` after granting
Accessibility makes macOS forget the permission - put it in Applications first.

<br>

## Hotkeys, and why F13-F24 are the right choice

Both settings windows record whatever you press. Anything with a modifier works, and so do **F13
through F24** on their own (macOS knows F13-F20).

Those keys are the reason this pairs well with a VIA or QMK keyboard: they exist in the keyboard
map, but no physical keyboard sends them and no application claims them. Map a spare key, an encoder
press or a layer key to F13 in VIA, bind it here, and you have a dedicated Fix key that can never
collide with an application shortcut.

A bare letter or digit is rejected on purpose - claiming `A` globally would break typing everywhere
on the machine.

Defaults are `Ctrl+Alt+J` on Windows and `Ctrl+Opt+J` on macOS.

<br>

## How it reads and replaces your text

### macOS: ask the app

macOS publishes the text under the caret through the Accessibility API, so TextFix asks for it. It
learns exactly what is selected rather than inferring it, spends no clipboard round trip, and
synthesises no keystrokes at all for the read. That is the path in native apps, Safari, Chrome and
most Electron hosts.

Putting the text **back** goes through the clipboard and a synthesised Cmd+V by default, even though
an Accessibility write would be faster. A paste travels the host's own paste path, so one Cmd+Z
undoes it in one step everywhere; a fair number of apps record nothing undoable for a direct write.
Settings > Behaviour will switch it if you would rather never touch the clipboard.

Hosts that publish nothing usable - a canvas-rendered editor, a game - fall back to the Windows
method below.

### Windows: copy, then paste over

Windows offers no way to ask another application for the text under its caret, so TextFix does what
your own hands would: copy, then paste over the same selection. Two details are worth knowing.

**Selection detection.** Windows will not tell an outside process whether the focused control has a
selection, and neither the clipboard contents nor its sequence number can answer that on their own -
copying the same text twice is byte-identical, and the sequence number moves for every writer on the
desktop, clipboard history and cloud sync included. So TextFix parks a unique marker on the
clipboard, presses Ctrl+C, and looks: the marker still being there means nothing was selected,
anything else is what the application copied. Only in the first case does it press Ctrl+A.

**Your clipboard comes back.** Whatever you were holding - text, files, an image, rich text - is
copied out before the probe and restored about 180 ms after the paste. The temporary text is flagged
so clipboard managers, Windows clipboard history (Win+V) and cloud clipboard all skip it. The macOS
fallback path does the same, using the `org.nspasteboard.TransientType` convention.

<br>

## Feedback while it works

A small dark capsule appears just below your caret with a light sweeping through it, then fades out
when the text lands. It brings its own contrast - soft drop shadow, hairline rim - so it stays
legible on a white document, a black editor or a photo, and it sits below the caret rather than
beside it so it never covers the text being fixed. It is click-through, never takes focus and never
appears in the window switcher. Applications that do not publish a caret position get it next to the
mouse pointer instead.

Failures arrive as something you can act on: a refused key, an account out of credit, a model that
does not exist. Windows uses a tray balloon; macOS draws its own HUD under the menu bar rather than
asking for notification permission, since the first thing it would ever have to say is "that did not
work". Both can be switched off if you want the agent completely silent.

<br>

## Privacy

- **Your key, your provider.** No middleman service, no account, no telemetry.
- **Zero data retention first.** On OpenRouter every request asks for a ZDR route. If routing cannot
  satisfy it, the request falls back to standard routing and tells you once per model rather than
  downgrading silently.
- **Reasoning off by default.** Copy-editing does not benefit from a scratchpad, and it costs
  seconds.
- **Password fields are refused.** On macOS this is reliable, because `AXSecureTextField` is
  reported by native controls and by password inputs inside Safari and Chrome. On Windows it is
  best-effort: the password style is visible on native controls, though not inside a browser.
- **The log records what happened, never what you wrote.** Lengths, statuses and error classes only,
  capped at 256 KB.
- **Nothing is sent until you press the hotkey.** The one exception is an unauthenticated TLS
  handshake to your provider to warm the connection, which carries no payload and no key.

<br>

## Settings reference

`config.json` is plain JSON and safe to hand-edit; the tray or menu bar menu opens the folder.
Everything from the settings window is here, plus a few knobs that are not.

| | Windows | macOS |
| --- | --- | --- |
| Config | `%APPDATA%\TextFix\config.json` | `~/Library/Application Support/TextFix/config.json` |
| Log | `%LOCALAPPDATA%\TextFix\textfix.log` | `~/Library/Logs/TextFix/textfix.log` |
| API key | `%APPDATA%\TextFix\secrets.dat` (DPAPI) | login keychain |

| Key | Default | What it does |
| --- | --- | --- |
| `provider` | `openrouter` | `openrouter` or `payperq`. |
| `model` | `~openai/gpt-mini-latest` | A slug from the picker, or `custom` with `customModel` set. |
| `zeroDataRetention` | `true` | Ask OpenRouter for a ZDR route. |
| `allowReasoning` | `false` | Let the model reason first. Slower. |
| `indicator` | `caret` | `caret`, `none`, plus `tray` on Windows / `menubar` on macOS. |
| `notifyOnError` | `true` | Show failures on screen. |
| `skipPasswordFields` | `true` | Refuse password controls. |
| `maxInputLength` | `10000` | Characters. Anything longer is refused rather than truncated. |
| `requestBudgetMs` | `90000` | Wall clock for the whole request, retries included. |
| `verboseLog` | `false` | Adds request-level detail. Still never your text. |
| `dryRun` | `false` | See Troubleshooting. |

Windows only:

| Key | Default | What it does |
| --- | --- | --- |
| `restoreClipboard` | `true` | Put your clipboard back after the paste. |
| `clipboardRestoreDelayMs` | `180` | Raise it if an application pastes the old clipboard content. |
| `pasteOnlyIfFocusUnchanged` | `true` | If you switch windows mid-request, the fixed text goes to your clipboard instead of into the wrong application. |
| `keyEventDelayMs` | `12` | Pause between the individual key events of a synthesised chord. Some apps (Telegram Desktop among them) drop a chord delivered as one atomic batch, so this is paid up front; it costs about 36 ms per chord. `0` restores atomic chords. |
| `startWithWindows` | `false` | Mirrors the per-user Run key. |

macOS only:

| Key | Default | What it does |
| --- | --- | --- |
| `replaceMode` | `paste` | `paste` keeps Cmd+Z working; `accessibility` writes the field directly and never touches the clipboard. |
| `useAccessibilityRead` | `true` | Read through the Accessibility API when the focused element supports it. Turning it off forces the clipboard path everywhere. |
| `restorePasteboard` | `true` | Put your clipboard back after the paste. |
| `pasteboardRestoreDelayMs` | `180` | Raise it if an application pastes the old clipboard content. |
| `replaceOnlyIfFocusUnchanged` | `true` | If you switch apps mid-request, the fixed text goes to your clipboard instead of into the wrong one. |
| `keyEventDelayMs` | `8` | Pause between the key-down and key-up of a synthesised chord. |

Run at login is not in `config.json` on macOS: `SMAppService` owns it, so the checkbox reads its
state back from System Settings > General > Login Items.

Both platforms share these on the clipboard fallback path: `selectionProbeMs` (`350`, how long to
wait for the probing copy - only spent when nothing is selected) and `copyTimeoutMs` (`700`, time
allowed for the whole-field read).

Per action: `enabled`, `hotkey`, `prompt`, `model` (empty means the top-level model) and
`wholeTextWhenNoSelection`.

### The `{text}` placeholder

A prompt can say where the captured text goes by including `{text}`:

```
Rewrite the text below ... Output only the revised text.

<text>
{text}
</text>
```

With a placeholder, the whole prompt is sent as one message with your text substituted in. That is
the only way a prompt can control how the input is fenced off, and fencing it is what stops
dictation containing something instruction-shaped ("scrap that, say instead...") from being obeyed
as an instruction. If a model echoes the tags back, they are stripped from the result.

Without a placeholder the prompt is sent as a system message and your text as a separate one, which
is the simpler shape and stays cacheable. Both work; the shipped Fix prompt uses a placeholder.

<br>

## Troubleshooting

**Nothing happens when I press the hotkey.** Set `"dryRun": true` in `config.json`, restart the agent
from its menu, and press the hotkey in a text box. Dry run does the entire pipeline - capture,
clipboard, replace, restore - but replaces the model call with UPPER CASE, so it sends nothing and
costs nothing. If your text comes back uppercased the plumbing works and the problem is the request;
if it does not, the log will name the step that stopped.

**On macOS, the hotkey does nothing at all.** Check Accessibility permission. Rebuilding or replacing
`TextFix.app` changes its signature, and macOS then treats it as a different app: remove the old
entry in System Settings > Privacy & Security > Accessibility with the minus button and add the new
one.

**"Another app already owns" that hotkey.** Something registered it first. Pick a different
combination, or an F13-F24 key.

**"Windows blocked the paste."** The target window belongs to a process running as administrator, and
Windows does not let a normal-rights program type into it. Nothing to fix from this side short of
running TextFix elevated too, which is a bigger tradeoff than it looks.

**A selection got treated as the whole field.** A few applications are slow to answer the copy. Raise
`selectionProbeMs`.

**In VS Code the whole line gets fixed when nothing is selected.** VS Code copies the current line on
copy with an empty selection, so from outside it is indistinguishable from a selection.

**The tray icon vanished.** Explorer restarted; the agent re-adds the icon automatically.

<br>

## Building

```powershell
.\build.ps1                 # -> dist\win-x64\TextFix.exe
.\build.ps1 -Zip            # -> TextFix-win-x64.zip
.\build.ps1 -Run            # publish and start it
.\build.ps1 -Rid win-arm64  # -> dist\win-arm64\TextFix.exe
```

Needs the .NET 9 SDK and the MSVC C++ build tools, which the Native AOT compiler links with. The
script puts `vswhere.exe` on PATH for you, so a Developer Command Prompt is not required.

```bash
./build-mac.sh                 # -> dist/macos/TextFix.app (universal)
./build-mac.sh --zip           # -> TextFix-macos-universal.zip
./build-mac.sh --run           # build and start it
./build-mac.sh --arch arm64    # single-architecture build
```

Needs the Xcode command line tools and nothing else. The icon is drawn at build time by
`src/TextFixMac/Tools/makeicon.swift`, so there is no asset to keep in step;
`tools/make-icon.py` does the same for the Windows `.ico` (needs Pillow).

CI builds both on every push. A release is a tag:

```bash
git tag v1.1.0 && git push origin v1.1.0
```

<br>

## Layout

```
src/TextFix/                 the Windows agent (C#, Win32, Native AOT)
  Program.cs                 single instance, then the message loop
  Core/                      agent window, hotkeys, orchestration, log, run-at-login
  Ai/                        the provider client: retries, routing, output sanitising
  Configuration/             config.json and the DPAPI key store
  Editing/                   clipboard, synthesised keys, capture and replace
  Ui/                        tray icon, caret pulse, settings window
  Interop/                   the Win32 surface this app uses

src/TextFixMac/              the macOS agent (Swift, AppKit)
  Sources/TextFix/
    main.swift               single instance, then NSApplication
    AppDelegate.swift        menu bar item, hotkeys, settings, wiring
    AppConfig.swift          config.json, same keys as Windows where they mean the same thing
    Keychain.swift           the API key
    Ai/                      the same provider client, ported
    Core/                    hotkeys, orchestration, permissions, login item
    Editing/                 Accessibility read and write, pasteboard, synthesised keys
    Ui/                      menu bar item, caret pulse, toast, settings window
  Tools/makeicon.swift       draws AppIcon.icns at build time
```

The two agents are separate programs, not one codebase with `#if` branches. Every line of both is
platform API calls - Win32 and AppKit have nothing in common to share - and the parts that *are*
shared, the provider protocol and the config format, are a specification that both implement rather
than code either one imports.

<br>

## Licence

GPL-3.0-only. `src/TextFix/Ai/` and `src/TextFixMac/Sources/TextFix/Ai/` are ports of the
`OpenRouterClient` from [WisprBoard](https://github.com/Turtlecute33/WisprBoard), an Android keyboard
under the same licence, which is where that requirement comes from. Everything else was written for
this project.
