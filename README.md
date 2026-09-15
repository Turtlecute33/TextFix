<div align="center">

# TextFix

### One keyboard shortcut. Your text, fixed in place.

Press your hotkey in any Windows text box. With text selected it fixes the selection; with nothing
selected it fixes the whole field. The result replaces what was there, and Ctrl+Z puts it back.

Bring your own [OpenRouter](https://openrouter.ai/) or [PayPerQ](https://ppq.ai/) key. No account,
no subscription, no telemetry.

</div>

<br>

## What it is

One self-contained 6 MB executable. No installer, no .NET runtime to install, no UI framework: the
tray icon, the settings window, the hotkeys and the on-screen indicator are all direct Win32 calls.
It sits in the tray using about 5 MB of private memory, burns no measurable CPU while idle, and does
nothing whatsoever until you press the hotkey.

```
Ctrl+Alt+J  in a text box, nothing selected  ->  the whole field comes back fixed
Ctrl+Alt+J  with text selected               ->  only the selection comes back fixed
```

Two actions ship configured, each with its own hotkey and its own editable prompt:

- **Fix** - rebuilds rough dictation into clean writing: mistranscribed words, mangled sentences,
  missing punctuation, repetition. Keeps your meaning, points and tone, and never translates.
- **Rewrite** - clearer and more concise, same meaning.

<br>

## Install

1. Download `TextFix.exe`, or build it yourself with `.\build.ps1`. Put it wherever you keep small
   tools; `%LOCALAPPDATA%\Programs\TextFix\` is a good spot.
2. Run it. The settings window opens on first launch and the tray icon appears.
3. Paste your API key, pick a model, press the hotkey you want into the capture box, tick **Start
   TextFix when I sign in**, and save.

Your key is encrypted with DPAPI under your Windows account in `%APPDATA%\TextFix\secrets.dat`. It
never goes into `config.json`.

<br>

## Hotkeys, and why F13-F24 are the right choice

The settings window records whatever you press. Anything with Ctrl, Alt or Shift works, and so does
**F13 through F24** on its own.

Those twelve keys are the reason this pairs well with a VIA or QMK keyboard: they exist in the
Windows keyboard map, but no physical keyboard sends them and no application claims them. Map a
spare key, an encoder press or a layer key to F13 in VIA, bind it here, and you have a dedicated Fix
key that can never collide with an application shortcut.

A bare letter or digit is rejected on purpose - claiming `A` globally would break typing everywhere
on the machine.

<br>

## How it reads and replaces your text

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
so clipboard managers, Windows clipboard history (Win+V) and cloud clipboard all skip it.

<br>

## Feedback while it works

A small dark capsule appears just below your caret with a light sweeping through it, then fades out
when the text lands. It brings its own contrast - soft drop shadow, hairline rim - so it stays
legible on a white document, a black editor or a photo, and it sits below the caret rather than
beside it so it never covers the text being fixed. It is click-through, never takes focus and never
appears in Alt+Tab. Applications that do not publish a caret position (Chromium, most Electron apps)
get it next to the mouse pointer instead.

Failures arrive as a tray balloon with something you can act on: a refused key, an account out of
credit, a model that does not exist. Both the indicator and the balloons can be switched off if you
want the agent completely silent.

<br>

## Privacy

- **Your key, your provider.** No middleman service, no account, no telemetry.
- **Zero data retention first.** On OpenRouter every request asks for a ZDR route. If routing cannot
  satisfy it, the request falls back to standard routing and tells you once per model rather than
  downgrading silently.
- **Reasoning off by default.** Copy-editing does not benefit from a scratchpad, and it costs
  seconds.
- **Password fields are refused.** Best-effort: the password style is visible on native Windows
  controls, though not inside a browser.
- **The log records what happened, never what you wrote.** Lengths, statuses and error classes only,
  capped at 256 KB, in `%LOCALAPPDATA%\TextFix\`.
- **Nothing is sent until you press the hotkey.** The one exception is an unauthenticated TLS
  handshake to your provider to warm the connection, which carries no payload and no key.

<br>

## Settings reference

`%APPDATA%\TextFix\config.json` is plain JSON and safe to hand-edit; the tray menu opens the folder.
Everything from the settings window is here, plus a few knobs that are not.

| Key | Default | What it does |
| --- | --- | --- |
| `provider` | `openrouter` | `openrouter` or `payperq`. |
| `model` | `~openai/gpt-mini-latest` | A slug from the picker, or `custom` with `customModel` set. |
| `zeroDataRetention` | `true` | Ask OpenRouter for a ZDR route. |
| `allowReasoning` | `false` | Let the model reason first. Slower. |
| `restoreClipboard` | `true` | Put your clipboard back after the paste. |
| `clipboardRestoreDelayMs` | `180` | Raise it if an application pastes the old clipboard content. |
| `indicator` | `caret` | `caret`, `tray` or `none`. |
| `notifyOnError` | `true` | Tray balloons for failures. |
| `pasteOnlyIfFocusUnchanged` | `true` | If you switch windows mid-request, the fixed text goes to your clipboard instead of into the wrong application. |
| `skipPasswordFields` | `true` | Refuse native password controls. |
| `selectionProbeMs` | `350` | How long to wait for the probing Ctrl+C. Only spent when nothing is selected. Raise it if a slow application makes selections look empty. |
| `copyTimeoutMs` | `700` | Time allowed for the whole-field read. |
| `keyEventDelayMs` | `12` | Pause between the individual key events of a synthesised chord. Some apps (Telegram Desktop among them) drop a chord delivered as one atomic batch, so this is paid up front; it costs about 36 ms per chord. `0` restores atomic chords. |
| `maxInputLength` | `10000` | Characters. Anything longer is refused rather than truncated. |
| `requestBudgetMs` | `90000` | Wall clock for the whole request, retries included. |
| `verboseLog` | `false` | Adds request-level detail. Still never your text. |
| `dryRun` | `false` | See below. |

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
from the tray, and press the hotkey in a text box. Dry run does the entire pipeline - probe,
clipboard, paste, restore - but replaces the model call with UPPER CASE, so it sends nothing and
costs nothing. If your text comes back uppercased the plumbing works and the problem is the request;
if it does not, the log will name the step that stopped.

**"Another app already owns" that hotkey.** Something registered it first. Pick a different
combination, or an F13-F24 key.

**"Windows blocked the paste."** The target window belongs to a process running as administrator, and
Windows does not let a normal-rights program type into it. Nothing to fix from this side short of
running TextFix elevated too, which is a bigger tradeoff than it looks.

**A selection got treated as the whole field.** A few applications are slow to answer Ctrl+C. Raise
`selectionProbeMs`.

**In VS Code the whole line gets fixed when nothing is selected.** VS Code copies the current line on
Ctrl+C with an empty selection, so from outside it is indistinguishable from a selection.

**The tray icon vanished.** Explorer restarted; the agent re-adds the icon automatically.

<br>

## Building

```powershell
.\build.ps1          # -> dist\TextFix.exe
.\build.ps1 -Zip     # -> TextFix-win-x64.zip
.\build.ps1 -Run     # publish and start it
```

Needs the .NET 9 SDK and the MSVC C++ build tools, which the Native AOT compiler links with. The
script puts `vswhere.exe` on PATH for you, so a Developer Command Prompt is not required. CI builds
the same way on `windows-latest`.

There are no NuGet dependencies. `tools/make-icon.py` regenerates the icon (needs Pillow).

<br>

## Layout

```
src/TextFix/
  Program.cs         single instance, then the message loop
  Core/              agent window, hotkeys, orchestration, log, run-at-login
  Ai/                the provider client: retries, routing, output sanitising
  Configuration/     config.json and the DPAPI key store
  Editing/           clipboard, synthesised keys, capture and replace
  Ui/                tray icon, caret pulse, settings window
  Interop/           the Win32 surface this app uses
```

<br>

## Licence

GPL-3.0-only. `src/TextFix/Ai/` is a port of the `OpenRouterClient` from
[WisprBoard](https://github.com/Turtlecute33/WisprBoard), an Android keyboard under the same licence,
which is where that requirement comes from. Everything else was written for this project.
