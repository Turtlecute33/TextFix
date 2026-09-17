// SPDX-License-Identifier: GPL-3.0-only
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using TextFix.Ai;
using TextFix.Core;
using TextFix.Interop;

namespace TextFix.Configuration;

/// <summary>
/// Stores provider API keys encrypted with DPAPI under the current user account. The ciphertext
/// is bound to this Windows user, so copying secrets.dat to another machine or another account
/// yields nothing.
///
/// The key never goes into config.json, which is a plain-text file people paste into bug reports.
/// </summary>
internal static class SecretStore
{
    private const string FileName = "secrets.dat";

    // Extra entropy mixed into DPAPI so a blob lifted out of this file cannot be decrypted by
    // another program simply because it runs as the same user.
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("TextFix.ApiKey.v1");

    private static string FilePath => Path.Combine(AppConfig.Directory, FileName);

    private static string KeyFor(AiProvider provider) => provider.ToPref();

    internal static string GetApiKey(AiProvider provider)
    {
        try
        {
            Dictionary<string, string> all = ReadAll();
            if (!all.TryGetValue(KeyFor(provider), out string? encoded) || string.IsNullOrEmpty(encoded))
            {
                return string.Empty;
            }
            byte[] cipher = Convert.FromBase64String(encoded);
            byte[]? plain = Unprotect(cipher);
            if (plain == null) return string.Empty;
            try
            {
                return Encoding.UTF8.GetString(plain);
            }
            finally
            {
                // The string itself cannot be wiped - it is an immutable, movable, GC-managed
                // object - but the decrypted bytes can be, and leaving a second copy of the key
                // lying in the heap for no reason is not a trade worth making.
                Array.Clear(plain);
            }
        }
        catch (Exception e)
        {
            // A blob that no longer decrypts (profile restored onto a new machine, for instance)
            // must read as "no key" rather than taking the whole feature down: re-entering it in
            // settings overwrites the bad blob and self-heals.
            Log.Warn("Could not read stored API key: " + e.GetType().Name);
            return string.Empty;
        }
    }

    internal static bool HasApiKey(AiProvider provider) => GetApiKey(provider).Length > 0;

    internal static void SetApiKey(AiProvider provider, string apiKey)
    {
        try
        {
            Dictionary<string, string> all = ReadAll();
            string trimmed = apiKey.Trim();
            if (trimmed.Length == 0)
            {
                all.Remove(KeyFor(provider));
            }
            else
            {
                byte[] plain = Encoding.UTF8.GetBytes(trimmed);
                byte[]? cipher;
                try
                {
                    cipher = Protect(plain);
                }
                finally
                {
                    Array.Clear(plain);
                }
                if (cipher == null)
                {
                    Log.Warn("DPAPI refused to encrypt the API key; it was not saved");
                    return;
                }
                all[KeyFor(provider)] = Convert.ToBase64String(cipher);
            }
            Directory.CreateDirectory(AppConfig.Directory);
            string json = JsonSerializer.Serialize(all, ConfigJson.Default.DictionaryStringString);
            string temp = FilePath + ".tmp";
            File.WriteAllText(temp, json);
            File.Move(temp, FilePath, overwrite: true);
        }
        catch (Exception e)
        {
            Log.Warn("Could not save API key: " + e.GetType().Name);
        }
    }

    private static Dictionary<string, string> ReadAll()
    {
        if (!File.Exists(FilePath)) return new Dictionary<string, string>(StringComparer.Ordinal);
        string json = File.ReadAllText(FilePath);
        if (string.IsNullOrWhiteSpace(json)) return new Dictionary<string, string>(StringComparer.Ordinal);
        return JsonSerializer.Deserialize(json, ConfigJson.Default.DictionaryStringString)
            ?? new Dictionary<string, string>(StringComparer.Ordinal);
    }

    private static unsafe byte[]? Protect(byte[] plain)
    {
        fixed (byte* plainPtr = plain)
        fixed (byte* entropyPtr = Entropy)
        {
            var input = new DATA_BLOB { cbData = (uint)plain.Length, pbData = (nint)plainPtr };
            var entropy = new DATA_BLOB { cbData = (uint)Entropy.Length, pbData = (nint)entropyPtr };
            if (!Win32.CryptProtectData(input, null, entropy, 0, 0, Win32.CRYPTPROTECT_UI_FORBIDDEN, out DATA_BLOB output))
            {
                return null;
            }
            return CopyAndFree(output);
        }
    }

    private static unsafe byte[]? Unprotect(byte[] cipher)
    {
        fixed (byte* cipherPtr = cipher)
        fixed (byte* entropyPtr = Entropy)
        {
            var input = new DATA_BLOB { cbData = (uint)cipher.Length, pbData = (nint)cipherPtr };
            var entropy = new DATA_BLOB { cbData = (uint)Entropy.Length, pbData = (nint)entropyPtr };
            if (!Win32.CryptUnprotectData(input, 0, entropy, 0, 0, Win32.CRYPTPROTECT_UI_FORBIDDEN, out DATA_BLOB output))
            {
                return null;
            }
            return CopyAndFree(output);
        }
    }

    private static byte[] CopyAndFree(DATA_BLOB blob)
    {
        try
        {
            byte[] result = new byte[blob.cbData];
            if (blob.cbData > 0) Marshal.Copy(blob.pbData, result, 0, (int)blob.cbData);
            return result;
        }
        finally
        {
            if (blob.pbData != 0) Win32.LocalFree(blob.pbData);
        }
    }
}
