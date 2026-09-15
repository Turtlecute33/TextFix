// SPDX-License-Identifier: GPL-3.0-only
using System.Text.Json;
using System.Text.Json.Serialization;
using TextFix.Core;

namespace TextFix.Configuration;

/// <summary>
/// Shipped defaults. The model and the two prompts are the ones this was ported from, and both
/// are a config edit away rather than a code change.
/// </summary>
internal static class Defaults
{
    internal const string Provider = "openrouter";
    internal const string Model = "~openai/gpt-mini-latest";
    internal const bool ZeroDataRetention = true;
    internal const bool AllowReasoning = false;

    /// <summary>
    /// The default Fix prompt. It carries a {text} placeholder, so the captured text is substituted
    /// into it and the whole thing goes out as one message - see AiText.Substitute. Delimiting the
    /// input in tags is what keeps dictation that happens to contain an instruction ("scrap that,
    /// say instead...") from being read as one.
    /// </summary>
    internal const string FixPrompt =
        """
        Rewrite the text below into clear, correct writing in the same language it's written in. Never translate.

        It's often rough dictation: transcription errors, wrong homophones, missing punctuation, run-on sentences, thinking out loud. Treat it as a sketch of what I meant, not text to correct word by word. Fix mistranscribed words, rebuild mangled sentences, cut repetition.

        Keep my meaning, my points, my tone. Add nothing. No em-dashes. Simple wording, paragraph breaks where useful.

        Output only the revised text.

        <text>
        {text}
        </text>
        """;

    internal const string RewritePrompt =
        "You are a writing assistant. Rewrite the following text to be clearer and more concise " +
        "while preserving the original meaning, tone, and language. Output only the rewritten " +
        "text, with no preamble, quotes, or explanation.";

    internal const int MaxInputLength = 10_000;
    internal const int MaxOutputLength = 10_000;
    internal const int RequestBudgetMs = 90_000;

    /// <summary>
    /// How long to leave the fixed text on the clipboard before restoring what was there before.
    /// Some hosts read the clipboard asynchronously after Ctrl+V returns, so restoring instantly
    /// makes the paste land as the old content.
    /// </summary>
    internal const int ClipboardRestoreDelayMs = 180;
}

internal sealed class FixActionConfig
{
    public string Name { get; set; } = "Fix";

    public bool Enabled { get; set; } = true;

    /// <summary>
    /// Human-readable combination, for example "Ctrl+Alt+J" or "F13". F13-F24 are the collision-free
    /// choice for a VIA-mapped key: nothing else on Windows claims them.
    /// </summary>
    public string Hotkey { get; set; } = "";

    public string Prompt { get; set; } = Defaults.FixPrompt;

    /// <summary>Empty means "use the model configured at the top level".</summary>
    public string Model { get; set; } = "";

    /// <summary>
    /// With nothing selected, select the whole field and fix all of it. Turning this off makes the
    /// action a no-op unless there is a selection - the safe choice for anyone who binds a key
    /// they might hit outside a text box.
    /// </summary>
    public bool WholeTextWhenNoSelection { get; set; } = true;
}

internal sealed class AppConfig
{
    public string Provider { get; set; } = Defaults.Provider;

    public string Model { get; set; } = Defaults.Model;

    public string CustomModel { get; set; } = "";

    public bool ZeroDataRetention { get; set; } = Defaults.ZeroDataRetention;

    public bool AllowReasoning { get; set; } = Defaults.AllowReasoning;

    public bool RestoreClipboard { get; set; } = true;

    public int ClipboardRestoreDelayMs { get; set; } = Defaults.ClipboardRestoreDelayMs;

    public int MaxInputLength { get; set; } = Defaults.MaxInputLength;

    public int RequestBudgetMs { get; set; } = Defaults.RequestBudgetMs;

    /// <summary>
    /// How long to wait for the probing Ctrl+C to land before concluding that nothing was
    /// selected. Only ever spent on the whole-field path - when there *is* a selection the copy
    /// registers in a few milliseconds and the wait ends early. Raise it if a slow app (some
    /// Electron editors) makes selections get treated as empty.
    /// </summary>
    public int SelectionProbeMs { get; set; } = 350;

    /// <summary>Time allowed for the Ctrl+A / Ctrl+C pair that reads a whole field.</summary>
    public int CopyTimeoutMs { get; set; } = 700;

    /// <summary>
    /// Pause between the individual key events of a synthesised chord.
    ///
    /// Defaults to 12 ms because atomic chords measurably do not work everywhere: Telegram
    /// Desktop ignores a Ctrl+A delivered as one batch and accepts the identical chord spaced
    /// out, and it is not going to be the only app like that. The cost is about 36 ms per chord,
    /// which is invisible next to a network round trip, so paying it up front beats discovering
    /// the need through a failed read. Set it to 0 to send each chord as a single atomic batch.
    /// </summary>
    public int KeyEventDelayMs { get; set; } = 12;

    /// <summary>"caret", "tray" or "none".</summary>
    public string Indicator { get; set; } = "caret";

    public bool NotifyOnError { get; set; } = true;

    /// <summary>
    /// Refuse to paste when focus moved while the request was in flight, and leave the fixed text
    /// on the clipboard instead. Without this a slow model can drop a paragraph into whatever
    /// window the user switched to.
    /// </summary>
    public bool PasteOnlyIfFocusUnchanged { get; set; } = true;

    /// <summary>
    /// Never read from a control with the password style. Best-effort - it can only be detected on
    /// native edit controls, not inside a browser - but it costs nothing and catches the common case.
    /// </summary>
    public bool SkipPasswordFields { get; set; } = true;

    public bool StartWithWindows { get; set; }

    /// <summary>Adds request-level detail to the log. Never includes the text being fixed.</summary>
    public bool VerboseLog { get; set; }

    /// <summary>
    /// Runs the whole pipeline - hotkey, selection probe, clipboard, paste, clipboard restore -
    /// but replaces the model call with an obvious local transformation (upper case) instead of
    /// sending anything anywhere. The way to prove the plumbing works in a particular app without
    /// an API key and without spending tokens.
    /// </summary>
    public bool DryRun { get; set; }

    public List<FixActionConfig> Actions { get; set; } =
    [
        new FixActionConfig { Name = "Fix", Enabled = true, Hotkey = "Ctrl+Alt+J", Prompt = Defaults.FixPrompt },
        new FixActionConfig { Name = "Rewrite", Enabled = false, Hotkey = "Ctrl+Alt+K", Prompt = Defaults.RewritePrompt },
    ];

    [JsonIgnore]
    internal bool WasCreatedFresh { get; set; }

    internal static string Directory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "TextFix");

    internal static string FilePath => Path.Combine(Directory, "config.json");

    internal static AppConfig Load()
    {
        try
        {
            if (!File.Exists(FilePath))
            {
                var fresh = new AppConfig { WasCreatedFresh = true };
                fresh.Save();
                return fresh;
            }
            string json = File.ReadAllText(FilePath);
            AppConfig? parsed = JsonSerializer.Deserialize(json, ConfigJson.Default.AppConfig);
            if (parsed == null)
            {
                Log.Warn("config.json parsed as null; using defaults");
                return new AppConfig();
            }
            parsed.Normalize();
            return parsed;
        }
        catch (Exception e)
        {
            // Deliberately does not overwrite the file: a hand-edit with one bad comma should not
            // cost the user their prompts and hotkeys.
            Log.Warn("Could not read config.json (" + e.GetType().Name + "); using defaults for this session");
            return new AppConfig();
        }
    }

    internal void Save()
    {
        try
        {
            System.IO.Directory.CreateDirectory(Directory);
            string json = JsonSerializer.Serialize(this, ConfigJson.Default.AppConfig);
            // Write-then-replace so a crash mid-write cannot leave a truncated config behind.
            string temp = FilePath + ".tmp";
            File.WriteAllText(temp, json);
            File.Move(temp, FilePath, overwrite: true);
        }
        catch (Exception e)
        {
            Log.Warn("Could not save config.json: " + e.GetType().Name);
        }
    }

    /// <summary>Clamps hand-edited values into ranges the rest of the app can rely on.</summary>
    internal void Normalize()
    {
        if (string.IsNullOrWhiteSpace(Provider)) Provider = Defaults.Provider;
        if (string.IsNullOrWhiteSpace(Model)) Model = Defaults.Model;
        if (string.IsNullOrWhiteSpace(Indicator)) Indicator = "caret";
        Indicator = Indicator.Trim().ToLowerInvariant();
        if (Indicator is not ("caret" or "tray" or "none")) Indicator = "caret";
        MaxInputLength = Math.Clamp(MaxInputLength, 100, 100_000);
        RequestBudgetMs = Math.Clamp(RequestBudgetMs, 5_000, 300_000);
        ClipboardRestoreDelayMs = Math.Clamp(ClipboardRestoreDelayMs, 0, 5_000);
        SelectionProbeMs = Math.Clamp(SelectionProbeMs, 50, 3_000);
        CopyTimeoutMs = Math.Clamp(CopyTimeoutMs, 100, 5_000);
        KeyEventDelayMs = Math.Clamp(KeyEventDelayMs, 0, 100);
        Actions ??= [];
        while (Actions.Count < 2)
        {
            Actions.Add(new FixActionConfig
            {
                Name = Actions.Count == 0 ? "Fix" : "Rewrite",
                Enabled = false,
                Hotkey = "",
                Prompt = Actions.Count == 0 ? Defaults.FixPrompt : Defaults.RewritePrompt,
            });
        }
        foreach (FixActionConfig action in Actions)
        {
            if (string.IsNullOrWhiteSpace(action.Prompt)) action.Prompt = Defaults.FixPrompt;
            action.Name = string.IsNullOrWhiteSpace(action.Name) ? "Fix" : action.Name.Trim();
        }
    }

    /// <summary>
    /// A detached copy for the settings window to edit, so cancelling changes nothing and the
    /// running agent keeps using the live values until the moment Save succeeds.
    /// </summary>
    internal AppConfig Clone()
    {
        string json = JsonSerializer.Serialize(this, ConfigJson.Default.AppConfig);
        AppConfig copy = JsonSerializer.Deserialize(json, ConfigJson.Default.AppConfig) ?? new AppConfig();
        copy.Normalize();
        return copy;
    }

    internal Ai.AiProvider ProviderValue => Ai.AiProviderExtensions.FromPref(Provider);

    /// <summary>The model slug for an action, or null when nothing usable is configured.</summary>
    internal string? ResolveModel(FixActionConfig action)
    {
        string selected = string.IsNullOrWhiteSpace(action.Model) ? Model : action.Model;
        return Ai.ModelCatalog.Resolve(selected, CustomModel);
    }
}

[JsonSourceGenerationOptions(
    WriteIndented = true,
    PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase,
    AllowTrailingCommas = true,
    ReadCommentHandling = JsonCommentHandling.Skip)]
[JsonSerializable(typeof(AppConfig))]
[JsonSerializable(typeof(Dictionary<string, string>))]
internal partial class ConfigJson : JsonSerializerContext;
