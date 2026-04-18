using System;
using System.Collections.Generic;
using System.IO;
using Newtonsoft.Json;

namespace TalkIsCheap.Models
{
    public class AppSettings
    {
        private static AppSettings? _instance;
        private static readonly object _lock = new();
        private static readonly string SettingsDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "TalkIsCheap");
        private static readonly string SettingsPath = Path.Combine(SettingsDir, "settings.json");

        public static AppSettings Shared
        {
            get
            {
                if (_instance == null)
                {
                    lock (_lock)
                    {
                        _instance ??= Load();
                    }
                }
                return _instance;
            }
        }

        // API Keys
        [JsonProperty("groqApiKey")]
        public string GroqApiKey { get; set; } = "";

        [JsonProperty("anthropicApiKey")]
        public string AnthropicApiKey { get; set; } = "";

        [JsonProperty("braveApiKey")]
        public string BraveApiKey { get; set; } = "";

        // Providers
        [JsonProperty("sttProvider")]
        public string SttProvider { get; set; } = "groq";

        [JsonProperty("polishProvider")]
        public string PolishProvider { get; set; } = "anthropic";

        // Local Whisper
        [JsonProperty("whisperModel")]
        public string WhisperModel { get; set; } = "large-v3-turbo";

        // Language
        [JsonProperty("language")]
        public string Language { get; set; } = "de";

        // Hotkey (Windows virtual key code, default = 163 for Right Ctrl)
        [JsonProperty("hotkeyCode")]
        public int HotkeyCode { get; set; } = 163;

        // Polish mode
        [JsonProperty("activePolishMode")]
        public string ActivePolishMode { get; set; } = "clean";

        [JsonProperty("appAwareContext")]
        public bool AppAwareContext { get; set; } = true;

        // Audio
        [JsonProperty("microphoneDevice")]
        public int MicrophoneDevice { get; set; } = 0;

        [JsonProperty("dimAudioWhileRecording")]
        public bool DimAudioWhileRecording { get; set; } = true;

        // License & Activation
        [JsonProperty("licenseKey")]
        public string LicenseKey { get; set; } = "";

        [JsonProperty("activationToken")]
        public string ActivationToken { get; set; } = "";

        [JsonProperty("activatedAt")]
        public string ActivatedAt { get; set; } = "";

        [JsonProperty("lastValidationCheck")]
        public double LastValidationCheck { get; set; } = 0;

        [JsonProperty("trialUses")]
        public int TrialUses { get; set; } = 0;

        // Onboarding
        [JsonProperty("hasCompletedOnboarding")]
        public bool HasCompletedOnboarding { get; set; } = false;

        // Search
        [JsonProperty("searchModel")]
        public string SearchModel { get; set; } = "claude-sonnet-4-6";

        // Cassette overlay size (1.0 = default, range 0.5 – 2.0)
        [JsonProperty("cassetteSize")]
        public double CassetteSize { get; set; } = 1.0;

        // Hands-free toggle: press once to start, press again to stop (vs. hold-to-record)
        [JsonProperty("handsFreeToggle")]
        public bool HandsFreeToggle { get; set; } = false;

        // Constants
        [JsonIgnore]
        public static string CurrentVersion => "2.0.0";

        [JsonIgnore]
        public static int TrialLimit => 50;

        [JsonIgnore]
        public bool IsTrialExpired => TrialUses >= TrialLimit;

        [JsonIgnore]
        public int RemainingTrial => Math.Max(0, TrialLimit - TrialUses);

        // Languages
        [JsonIgnore]
        public static readonly List<(string Code, string Name)> Languages = new()
        {
            ("auto", "Auto-Detect"),
            ("de", "Deutsch"),
            ("en", "English"),
            ("fr", "Fran\u00e7ais"),
            ("es", "Espa\u00f1ol"),
            ("it", "Italiano"),
            ("pt", "Portugu\u00eas"),
            ("nl", "Nederlands"),
            ("ja", "\u65e5\u672c\u8a9e"),
            ("zh", "\u4e2d\u6587"),
        };

        // Hotkey display names
        [JsonIgnore]
        public string HotkeyName
        {
            get
            {
                return HotkeyCode switch
                {
                    162 or 163 => "Control",
                    160 or 161 => "Shift",
                    164 or 165 => "Alt",
                    20 => "CapsLock",
                    >= 112 and <= 135 => $"F{HotkeyCode - 111}",
                    _ => $"Key({HotkeyCode})"
                };
            }
        }

        [JsonIgnore]
        public string HotkeyShort
        {
            get
            {
                return HotkeyCode switch
                {
                    162 or 163 => "Ctrl",
                    160 or 161 => "Shift",
                    164 or 165 => "Alt",
                    20 => "CapsLock",
                    >= 112 and <= 135 => $"F{HotkeyCode - 111}",
                    _ => $"Key({HotkeyCode})"
                };
            }
        }

        // Persistence
        private static AppSettings Load()
        {
            try
            {
                if (File.Exists(SettingsPath))
                {
                    var json = File.ReadAllText(SettingsPath);
                    var settings = JsonConvert.DeserializeObject<AppSettings>(json);
                    if (settings != null) return settings;
                }
            }
            catch (Exception ex)
            {
                Services.Logger.Write($"Failed to load settings: {ex.Message}");
            }
            return new AppSettings();
        }

        public void Save()
        {
            try
            {
                Directory.CreateDirectory(SettingsDir);
                var json = JsonConvert.SerializeObject(this, Formatting.Indented);
                File.WriteAllText(SettingsPath, json);
            }
            catch (Exception ex)
            {
                Services.Logger.Write($"Failed to save settings: {ex.Message}");
            }
        }
    }
}
