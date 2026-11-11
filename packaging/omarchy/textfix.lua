-- Load with dofile("/usr/share/textfix/omarchy/textfix.lua") in ~/.config/hypr/bindings.lua.
-- Release bindings avoid forwarding a shortcut while its physical modifiers are still held.
hl.bind("CTRL + ALT + J", hl.dsp.exec_cmd("textfix fix"), { release = true, description = "TextFix: fix text" })
hl.bind("CTRL + ALT + K", hl.dsp.exec_cmd("textfix rewrite"), { release = true, description = "TextFix: rewrite text" })
-- For a VIA/QMK keyboard, change the chords above to F13 and F14 if preferred.
