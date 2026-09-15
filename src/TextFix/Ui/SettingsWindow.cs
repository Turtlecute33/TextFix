// SPDX-License-Identifier: GPL-3.0-only
using System.Runtime.InteropServices;
using TextFix.Ai;
using TextFix.Configuration;
using TextFix.Core;
using TextFix.Interop;

namespace TextFix.Ui;

/// <summary>
/// The settings window, built directly on Win32 common controls so the resident process never
/// loads a UI framework. It exists only while open: closing it destroys every handle and the agent
/// goes back to its tray icon and its hotkeys.
///
/// Hotkey capture uses the system msctls_hotkey32 control, which is the one piece of Win32 built
/// exactly for this job - the user presses the combination and the control reports it.
/// </summary>
internal sealed unsafe class SettingsWindow
{
    private const string ClassName = "TextFixSettingsWnd";

    // Windows sends IDOK for the default button and IDCANCEL for Esc, so the two buttons take
    // those ids and Enter / Esc work without a dialog template.
    private const int IdOk = 1;
    private const int IdCancel = 2;
    private const int IdProvider = 101;
    private const int IdApiKey = 102;
    private const int IdModel = 103;
    private const int IdCustomModel = 104;
    private const int IdZdr = 105;
    private const int IdReasoning = 106;
    private const int IdRestoreClipboard = 107;
    private const int IdNotify = 108;
    private const int IdAutostart = 109;
    private const int IdIndicator = 110;
    private const int IdActionBase = 200;
    private const int IdActionStride = 10;
    private const int IdActionEnabledOffset = 0;
    private const int IdActionHotkeyOffset = 1;
    private const int IdActionPromptOffset = 2;
    private const int IdActionWholeOffset = 3;

    // Window messages for the controls we drive.
    private const uint BM_GETCHECK = 0x00F0;
    private const uint BM_SETCHECK = 0x00F1;
    private const uint CB_ADDSTRING = 0x0143;
    private const uint CB_SETCURSEL = 0x014E;
    private const uint CB_GETCURSEL = 0x0147;
    private const uint EM_LIMITTEXT = 0x00C5;
    private const uint HKM_SETHOTKEY = 0x0401;
    private const uint HKM_GETHOTKEY = 0x0402;

    private const uint BS_AUTOCHECKBOX = 0x0003;
    private const uint BS_DEFPUSHBUTTON = 0x0001;
    private const uint BS_PUSHBUTTON = 0x0000;
    private const uint CBS_DROPDOWNLIST = 0x0003;
    private const uint ES_MULTILINE = 0x0004;
    private const uint ES_AUTOVSCROLL = 0x0040;
    private const uint ES_AUTOHSCROLL = 0x0080;
    private const uint ES_PASSWORD = 0x0020;
    private const uint ES_WANTRETURN = 0x1000;
    private const uint SS_ETCHEDHORZ = 0x0010;

    private const string KeyPlaceholder = "••••••••••••";
    private const int PromptLimit = 4000;

    private static SettingsWindow? _instance;
    private static bool _classRegistered;

    private readonly AppConfig _config;
    private readonly Action<AppConfig?> _onClosed;
    private readonly Dictionary<int, nint> _controls = [];

    private nint _hwnd;
    private nint _font;
    private nint _boldFont;
    private uint _dpi = 96;
    private AiProvider _provider;
    private ModelEntry[] _models = [];
    private bool _apiKeyDirty;

    internal SettingsWindow(AppConfig config, Action<AppConfig?> onClosed)
    {
        _config = config.Clone();
        _onClosed = onClosed;
        _provider = _config.ProviderValue;
    }

    internal nint Handle => _hwnd;

    internal void Focus()
    {
        if (_hwnd == 0) return;
        Win32.ShowWindow(_hwnd, Win32.SW_RESTORE);
        Win32.SetForegroundWindow(_hwnd);
    }

    private const uint WindowStyle = WS.OVERLAPPED | WS.CAPTION | WS.SYSMENU | WS.CLIPCHILDREN;

    /// <summary>Client-area design size, in 96-dpi units.</summary>
    private const int DesignWidth = 616;
    private const int DesignHeight = 628;

    internal bool Show(nint owner)
    {
        _instance = this;
        RegisterClass();

        // Created off-screen at a provisional size, then measured and placed: on a mixed-DPI
        // desktop the owner's scale is not necessarily the scale this window will open at, and
        // the frame around a given client area is itself DPI-dependent.
        _hwnd = Win32.CreateWindowEx(
            0, ClassName, "TextFix settings", WindowStyle,
            -32000, -32000, 400, 300, owner, 0, NativeUi.Instance, 0);
        if (_hwnd == 0)
        {
            Log.Error("Could not create the settings window (" + Marshal.GetLastWin32Error() + ")");
            _instance = null;
            return false;
        }

        _dpi = NativeUi.DpiFor(_hwnd);
        ResizeToDesign();
        _font = NativeUi.CreateUiFont(_dpi);
        _boldFont = NativeUi.CreateUiFont(_dpi, bold: true);
        nint icon = NativeUi.LoadAppIcon(32);
        if (icon != 0) Win32.SendMessage(_hwnd, WM.SETICON, 1, icon);

        BuildControls();
        LoadValues();

        Win32.ShowWindow(_hwnd, Win32.SW_SHOW);
        Win32.SetForegroundWindow(_hwnd);
        return true;
    }

    private int Scale(int value) => NativeUi.Scale(value, _dpi);

    /// <summary>
    /// Sizes the window so its client area is exactly the scaled design size, and centres it on
    /// the pointer - which is where the user just clicked the tray icon.
    /// </summary>
    private void ResizeToDesign()
    {
        var frame = new RECT { Left = 0, Top = 0, Right = Scale(DesignWidth), Bottom = Scale(DesignHeight) };
        if (!Win32.AdjustWindowRectExForDpi(ref frame, WindowStyle, false, 0, _dpi))
        {
            // Older builds without the per-dpi variant: fall back to the scaled client size plus
            // a generous frame allowance rather than leaving the buttons off the bottom edge.
            frame = new RECT
            {
                Left = 0,
                Top = 0,
                Right = Scale(DesignWidth) + Scale(16),
                Bottom = Scale(DesignHeight) + Scale(40),
            };
        }
        int width = frame.Width;
        int height = frame.Height;

        int x = 200;
        int y = 200;
        if (Win32.GetCursorPos(out POINT cursor))
        {
            x = cursor.X - width / 2;
            y = cursor.Y - height / 2;
        }
        NativeUi.ClampToScreen(ref x, ref y, width, height);
        Win32.SetWindowPos(_hwnd, 0, x, y, width, height, Win32.SWP_NOZORDER | Win32.SWP_NOACTIVATE);
    }

    private void RegisterClass()
    {
        if (_classRegistered) return;
        fixed (char* className = ClassName)
        {
            var windowClass = new WNDCLASSEXW
            {
                cbSize = (uint)sizeof(WNDCLASSEXW),
                lpfnWndProc = (nint)(delegate* unmanaged<nint, uint, nuint, nint, nint>)&StaticWndProc,
                hInstance = NativeUi.Instance,
                lpszClassName = className,
                hbrBackground = Win32.GetSysColorBrush(Win32.COLOR_BTNFACE),
                hCursor = Win32.LoadCursor(0, 32512 /* IDC_ARROW */),
                hIcon = NativeUi.LoadAppIcon(32),
            };
            Win32.RegisterClassEx(&windowClass);
        }
        _classRegistered = true;
    }

    // ---- layout ----

    private void BuildControls()
    {
        const int labelX = 16;
        const int labelW = 128;
        const int fieldX = 152;
        const int rowH = 24;
        const int checkH = 22;
        int y = 14;

        Label(labelX, y + 4, labelW, 18, "Provider");
        nint provider = Combo(fieldX, y, 200, IdProvider);
        AddString(provider, "OpenRouter");
        AddString(provider, "PayPerQ");
        y += 32;

        Label(labelX, y + 4, labelW, 18, "API key");
        nint apiKey = Edit(fieldX, y, 448, rowH, IdApiKey, ES_PASSWORD | ES_AUTOHSCROLL);
        Win32.SendMessage(apiKey, EM_LIMITTEXT, 256, 0);
        y += 32;

        Label(labelX, y + 4, labelW, 18, "Model");
        Combo(fieldX, y, 300, IdModel);
        y += 32;

        Label(labelX, y + 4, labelW, 18, "Custom model");
        Edit(fieldX, y, 300, rowH, IdCustomModel, ES_AUTOHSCROLL);
        y += 34;

        Checkbox(fieldX, y, 448, checkH, IdZdr, "Ask for zero-data-retention routing (OpenRouter)");
        y += 26;
        Checkbox(fieldX, y, 448, checkH, IdReasoning, "Let the model reason before answering (slower)");
        y += 26;
        Checkbox(fieldX, y, 448, checkH, IdRestoreClipboard, "Put my clipboard back after replacing text");
        y += 26;
        Checkbox(fieldX, y, 448, checkH, IdNotify, "Show failures as tray notifications");
        y += 26;
        Checkbox(fieldX, y, 448, checkH, IdAutostart, "Start TextFix when I sign in");
        y += 32;

        Label(labelX, y + 4, labelW, 18, "While working");
        nint indicator = Combo(fieldX, y, 220, IdIndicator);
        AddString(indicator, "Pulse next to the caret");
        AddString(indicator, "Tray icon only");
        AddString(indicator, "Show nothing");
        y += 38;

        y = BuildActionBlock(y, 0, "Action 1");
        y = BuildActionBlock(y, 1, "Action 2");

        Label(labelX, y + 8, 420, 34,
            "Nothing selected fixes the whole field; a selection fixes just the selection." +
            " F13-F24 make good VIA-mapped hotkeys - nothing else on Windows claims them.");

        Button(438, y + 6, 84, 28, IdOk, "Save", isDefault: true);
        Button(528, y + 6, 84, 28, IdCancel, "Cancel", isDefault: false);
    }

    private int BuildActionBlock(int y, int index, string title)
    {
        Separator(16, y, 596);
        LabelBold(16, y + 6, 120, 18, title);
        y += 28;

        int baseId = IdActionBase + index * IdActionStride;
        Checkbox(16, y, 90, 22, baseId + IdActionEnabledOffset, "Enabled");
        Label(112, y + 4, 46, 18, "Hotkey");
        Hotkey(162, y, 150, 24, baseId + IdActionHotkeyOffset);
        Checkbox(326, y, 286, 22, baseId + IdActionWholeOffset, "Whole field when nothing is selected");
        y += 28;

        nint prompt = Edit(16, y, 596, 62, baseId + IdActionPromptOffset,
            ES_MULTILINE | ES_AUTOVSCROLL | ES_WANTRETURN | WS.VSCROLL);
        Win32.SendMessage(prompt, EM_LIMITTEXT, PromptLimit, 0);
        return y + 72;
    }

    private nint Add(int id, nint control)
    {
        if (control != 0)
        {
            Win32.SendMessage(control, WM.SETFONT, (nuint)_font, 1);
            _controls[id] = control;
        }
        return control;
    }

    private nint Create(string className, string? text, uint style, int x, int y, int w, int h, int id, uint exStyle = 0)
    {
        nint control = Win32.CreateWindowEx(
            exStyle, className, text, WS.CHILD | WS.VISIBLE | style,
            Scale(x), Scale(y), Scale(w), Scale(h), _hwnd, id, NativeUi.Instance, 0);
        return Add(id, control);
    }

    private void Label(int x, int y, int w, int h, string text) =>
        Create("STATIC", text, 0, x, y, w, h, NextStaticId());

    private void LabelBold(int x, int y, int w, int h, string text)
    {
        nint control = Create("STATIC", text, 0, x, y, w, h, NextStaticId());
        if (control != 0) Win32.SendMessage(control, WM.SETFONT, (nuint)_boldFont, 1);
    }

    private void Separator(int x, int y, int w) =>
        Create("STATIC", null, SS_ETCHEDHORZ, x, y, w, 2, NextStaticId());

    private int _nextStaticId = 5000;

    private int NextStaticId() => _nextStaticId++;

    private nint Edit(int x, int y, int w, int h, int id, uint extraStyle) =>
        Create("EDIT", null, WS.TABSTOP | WS.BORDER | extraStyle, x, y, w, h, id);

    private nint Combo(int x, int y, int w, int id) =>
        // The height passed to a drop-down list is the dropped height; the closed control sizes
        // itself to the font.
        Create("COMBOBOX", null, WS.TABSTOP | WS.VSCROLL | CBS_DROPDOWNLIST, x, y, w, 200, id);

    private nint Checkbox(int x, int y, int w, int h, int id, string text) =>
        Create("BUTTON", text, WS.TABSTOP | BS_AUTOCHECKBOX, x, y, w, h, id);

    private nint Hotkey(int x, int y, int w, int h, int id) =>
        Create("msctls_hotkey32", null, WS.TABSTOP | WS.BORDER, x, y, w, h, id);

    private nint Button(int x, int y, int w, int h, int id, string text, bool isDefault) =>
        Create("BUTTON", text, WS.TABSTOP | (isDefault ? BS_DEFPUSHBUTTON : BS_PUSHBUTTON), x, y, w, h, id);

    private static void AddString(nint combo, string value)
    {
        if (combo != 0) Win32.SendMessageString(combo, CB_ADDSTRING, 0, value);
    }

    private nint Control(int id) => _controls.TryGetValue(id, out nint handle) ? handle : 0;

    // ---- values ----

    private void LoadValues()
    {
        SetComboIndex(IdProvider, _provider == AiProvider.PayPerQ ? 1 : 0);
        PopulateModels();

        SetText(IdApiKey, SecretStore.HasApiKey(_provider) ? KeyPlaceholder : string.Empty);
        _apiKeyDirty = false;
        SetText(IdCustomModel, _config.CustomModel);

        SetCheck(IdZdr, _config.ZeroDataRetention);
        SetCheck(IdReasoning, _config.AllowReasoning);
        SetCheck(IdRestoreClipboard, _config.RestoreClipboard);
        SetCheck(IdNotify, _config.NotifyOnError);
        SetCheck(IdAutostart, Autostart.IsEnabled());
        SetComboIndex(IdIndicator, _config.Indicator switch
        {
            "tray" => 1,
            "none" => 2,
            _ => 0,
        });

        for (int i = 0; i < 2 && i < _config.Actions.Count; i++)
        {
            FixActionConfig action = _config.Actions[i];
            int baseId = IdActionBase + i * IdActionStride;
            SetCheck(baseId + IdActionEnabledOffset, action.Enabled);
            SetCheck(baseId + IdActionWholeOffset, action.WholeTextWhenNoSelection);
            SetText(baseId + IdActionPromptOffset, action.Prompt);
            HotkeyBinding.TryParse(action.Hotkey, out HotkeyBinding binding);
            nint hotkey = Control(baseId + IdActionHotkeyOffset);
            if (hotkey != 0) Win32.SendMessage(hotkey, HKM_SETHOTKEY, binding.ToControlValue(), 0);
        }

        UpdateEnabledState();
    }

    private void PopulateModels()
    {
        nint combo = Control(IdModel);
        if (combo == 0) return;
        const uint CB_RESETCONTENT = 0x014B;
        Win32.SendMessage(combo, CB_RESETCONTENT, 0, 0);

        _models = ModelCatalog.For(_provider);
        string selected = _config.Model;
        int selectedIndex = -1;
        for (int i = 0; i < _models.Length; i++)
        {
            ModelEntry entry = _models[i];
            string tier = entry.Tier switch
            {
                PricingTier.Free => "free",
                PricingTier.Cheap => "cheap",
                PricingTier.Medium => "medium",
                _ => "pricey",
            };
            string label = entry.DisplayName + "  -  " + tier;
            if (entry.Zdr) label += ", ZDR";
            if (entry.Cache) label += ", cached";
            AddString(combo, label);
            if (entry.Slug == selected) selectedIndex = i;
        }
        AddString(combo, "Custom model slug");
        if (selected == ModelCatalog.CustomSlug) selectedIndex = _models.Length;
        // A model saved for the other provider is not silently kept: falling back to the first
        // entry is the same behaviour the keyboard has when you switch providers.
        SetComboIndex(IdModel, selectedIndex >= 0 ? selectedIndex : 0);
    }

    private void UpdateEnabledState()
    {
        bool custom = GetComboIndex(IdModel) == _models.Length;
        Win32.EnableWindow(Control(IdCustomModel), custom);
        // Zero data retention is an OpenRouter routing preference; on PayPerQ it is a property of
        // the model you pick, so the checkbox would promise something it cannot deliver.
        Win32.EnableWindow(Control(IdZdr), _provider == AiProvider.OpenRouter);
    }

    private bool Collect(out AppConfig result)
    {
        result = _config;

        result.Provider = _provider.ToPref();
        int modelIndex = GetComboIndex(IdModel);
        result.Model = modelIndex >= 0 && modelIndex < _models.Length
            ? _models[modelIndex].Slug
            : ModelCatalog.CustomSlug;
        result.CustomModel = GetText(IdCustomModel).Trim();

        if (result.Model == ModelCatalog.CustomSlug && !ModelCatalog.IsValidCustomSlug(result.CustomModel))
        {
            Complain("That does not look like a model slug. Use author/model, for example openai/gpt-4o-mini.");
            return false;
        }
        if (result.Model == ModelCatalog.CustomSlug && result.CustomModel.Length == 0)
        {
            Complain("Enter a custom model slug, or pick one from the list.");
            return false;
        }

        result.ZeroDataRetention = GetCheck(IdZdr);
        result.AllowReasoning = GetCheck(IdReasoning);
        result.RestoreClipboard = GetCheck(IdRestoreClipboard);
        result.NotifyOnError = GetCheck(IdNotify);
        result.Indicator = GetComboIndex(IdIndicator) switch
        {
            1 => "tray",
            2 => "none",
            _ => "caret",
        };

        for (int i = 0; i < 2 && i < result.Actions.Count; i++)
        {
            FixActionConfig action = result.Actions[i];
            int baseId = IdActionBase + i * IdActionStride;
            action.Enabled = GetCheck(baseId + IdActionEnabledOffset);
            action.WholeTextWhenNoSelection = GetCheck(baseId + IdActionWholeOffset);
            action.Prompt = GetText(baseId + IdActionPromptOffset).Trim();
            if (action.Prompt.Length == 0) action.Prompt = i == 0 ? Defaults.FixPrompt : Defaults.RewritePrompt;

            nint hotkeyControl = Control(baseId + IdActionHotkeyOffset);
            ushort raw = hotkeyControl == 0 ? (ushort)0 : (ushort)Win32.SendMessage(hotkeyControl, HKM_GETHOTKEY, 0, 0);
            HotkeyBinding binding = HotkeyBinding.FromControlValue(raw);
            if (action.Enabled && binding.IsEmpty)
            {
                Complain("Give " + action.Name + " a hotkey, or turn it off.");
                return false;
            }
            if (!binding.IsEmpty && binding.Modifiers == 0 && !IsSafeUnmodifiedKey(binding.VirtualKey))
            {
                Complain(
                    binding.Format() + " on its own would be swallowed everywhere on this machine." +
                    " Add Ctrl, Alt or Shift, or use one of F13-F24.");
                return false;
            }
            action.Hotkey = binding.Format();
        }

        if (result.Actions.Count >= 2
            && result.Actions[0].Enabled && result.Actions[1].Enabled
            && result.Actions[0].Hotkey.Length > 0
            && string.Equals(result.Actions[0].Hotkey, result.Actions[1].Hotkey, StringComparison.OrdinalIgnoreCase))
        {
            Complain("Both actions are on " + result.Actions[0].Hotkey + ". Give them different hotkeys.");
            return false;
        }

        // The API key is written straight to the secret store rather than into the config object,
        // so it never passes through config.json.
        if (_apiKeyDirty)
        {
            string typed = GetText(IdApiKey);
            if (typed != KeyPlaceholder) SecretStore.SetApiKey(_provider, typed);
        }
        Autostart.SetEnabled(GetCheck(IdAutostart));
        result.StartWithWindows = GetCheck(IdAutostart);
        return true;
    }

    /// <summary>
    /// F13-F24 exist precisely because no keyboard sends them by accident, which makes them the
    /// only keys worth claiming globally without a modifier.
    /// </summary>
    private static bool IsSafeUnmodifiedKey(uint vk) => vk is >= 0x7C and <= 0x87;

    private void Complain(string message) =>
        Win32.MessageBox(_hwnd, message, "TextFix settings", Win32.MB_ICONWARNING);

    // ---- control accessors ----

    private void SetText(int id, string value)
    {
        nint control = Control(id);
        if (control != 0) Win32.SetWindowText(control, value);
    }

    private string GetText(int id)
    {
        nint control = Control(id);
        return control == 0 ? string.Empty : Win32.GetWindowTextValue(control);
    }

    private void SetCheck(int id, bool value)
    {
        nint control = Control(id);
        if (control != 0) Win32.SendMessage(control, BM_SETCHECK, value ? 1u : 0u, 0);
    }

    private bool GetCheck(int id)
    {
        nint control = Control(id);
        return control != 0 && Win32.SendMessage(control, BM_GETCHECK, 0, 0) == 1;
    }

    private void SetComboIndex(int id, int index)
    {
        nint control = Control(id);
        if (control != 0) Win32.SendMessage(control, CB_SETCURSEL, (nuint)index, 0);
    }

    private int GetComboIndex(int id)
    {
        nint control = Control(id);
        return control == 0 ? -1 : (int)Win32.SendMessage(control, CB_GETCURSEL, 0, 0);
    }

    // ---- messages ----

    [UnmanagedCallersOnly]
    private static nint StaticWndProc(nint hwnd, uint message, nuint wParam, nint lParam)
    {
        SettingsWindow? self = _instance;
        if (self != null && (self._hwnd == hwnd || self._hwnd == 0))
        {
            nint? handled = self.HandleMessage(hwnd, message, wParam, lParam);
            if (handled.HasValue) return handled.Value;
        }
        return Win32.DefWindowProc(hwnd, message, wParam, lParam);
    }

    private nint? HandleMessage(nint hwnd, uint message, nuint wParam, nint lParam)
    {
        switch (message)
        {
            case WM.COMMAND:
                OnCommand((int)(wParam & 0xFFFF), (int)((wParam >> 16) & 0xFFFF));
                return 0;

            case WM.CTLCOLORSTATIC:
                // Static text and checkbox labels sit on the dialog background, not on white.
                Win32.SetBkColor((nint)wParam, Win32.GetSysColor(Win32.COLOR_BTNFACE));
                return Win32.GetSysColorBrush(Win32.COLOR_BTNFACE);

            case WM.CLOSE:
                Close(null);
                return 0;

            case WM.DESTROY:
                ReleaseResources();
                return 0;
        }
        return null;
    }

    private void OnCommand(int controlId, int notification)
    {
        const int CBN_SELCHANGE = 1;
        const int EN_CHANGE = 0x0300;

        switch (controlId)
        {
            case IdOk:
                if (Collect(out AppConfig collected)) Close(collected);
                return;
            case IdCancel:
                Close(null);
                return;
            case IdProvider when notification == CBN_SELCHANGE:
                _provider = GetComboIndex(IdProvider) == 1 ? AiProvider.PayPerQ : AiProvider.OpenRouter;
                // Each provider has its own key and its own model namespace, so both fields follow
                // the selection instead of carrying a value that would fail on the new provider.
                SetText(IdApiKey, SecretStore.HasApiKey(_provider) ? KeyPlaceholder : string.Empty);
                _apiKeyDirty = false;
                if (!ModelCatalog.Supports(_provider, _config.Model)) _config.Model = ModelCatalog.For(_provider)[0].Slug;
                PopulateModels();
                UpdateEnabledState();
                return;
            case IdModel when notification == CBN_SELCHANGE:
                _config.Model = GetComboIndex(IdModel) < _models.Length
                    ? _models[Math.Max(GetComboIndex(IdModel), 0)].Slug
                    : ModelCatalog.CustomSlug;
                UpdateEnabledState();
                return;
            case IdApiKey when notification == EN_CHANGE:
                _apiKeyDirty = true;
                return;
        }
    }

    private void Close(AppConfig? result)
    {
        nint hwnd = _hwnd;
        _hwnd = 0;
        Action<AppConfig?> callback = _onClosed;
        if (hwnd != 0) Win32.DestroyWindow(hwnd);
        _instance = null;
        callback(result);
    }

    private void ReleaseResources()
    {
        if (_font != 0)
        {
            Win32.DeleteObject(_font);
            _font = 0;
        }
        if (_boldFont != 0)
        {
            Win32.DeleteObject(_boldFont);
            _boldFont = 0;
        }
        _controls.Clear();
    }
}
