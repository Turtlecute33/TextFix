-- Load with dofile("/usr/share/textfix/omarchy/textfix.lua") in ~/.config/hypr/bindings.lua.
-- The bindings run on key press. TextFix sends its copy and paste through Hyprland with the
-- modifiers given explicitly, so the keys that you still hold do not change them.
hl.bind("CTRL + ALT + J", hl.dsp.exec_cmd("textfix fix"), { description = "TextFix: fix text" })
hl.bind("CTRL + ALT + K", hl.dsp.exec_cmd("textfix rewrite"), { description = "TextFix: rewrite text" })
-- For a VIA/QMK keyboard, change the chords above to F13 and F14: no app uses those keys.
-- A binding with { release = true } runs only if you let go of the letter before the modifiers.
