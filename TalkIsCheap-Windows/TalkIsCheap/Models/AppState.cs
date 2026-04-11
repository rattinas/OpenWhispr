using System;
using System.Diagnostics;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using TalkIsCheap.Services;

namespace TalkIsCheap.Models
{
    public enum AppStatus
    {
        Ready,
        Recording,
        Transcribing,
        Polishing,
        Done,
        Error
    }

    public class AppState
    {
        private static AppState? _instance;
        private static readonly object _lock = new();

        public static AppState Shared
        {
            get
            {
                if (_instance == null)
                {
                    lock (_lock)
                    {
                        _instance ??= new AppState();
                    }
                }
                return _instance;
            }
        }

        public AppStatus Status { get; private set; } = AppStatus.Ready;
        public string StatusDetail { get; private set; } = "";
        public int LastWordCount { get; private set; }
        public double LastDuration { get; private set; }

        public event Action? StatusChanged;

        private readonly AudioRecorder _recorder = new();
        private readonly AppSettings _settings = AppSettings.Shared;
        private readonly PolishModeManager _modeManager = PolishModeManager.Shared;
        private readonly TranscriptionHistory _history = TranscriptionHistory.Shared;

        public bool IsRecording => _recorder.IsRecording;

        public string StatusText
        {
            get
            {
                return Status switch
                {
                    AppStatus.Ready => $"Ready -- hold {_settings.HotkeyShort} to dictate",
                    AppStatus.Recording => "Recording...",
                    AppStatus.Transcribing => "Transcribing...",
                    AppStatus.Polishing => "Polishing...",
                    AppStatus.Done => $"Done: {LastWordCount} words in {LastDuration:F1}s",
                    AppStatus.Error => $"Error: {StatusDetail}",
                    _ => "Ready"
                };
            }
        }

        private void SetStatus(AppStatus status, string detail = "")
        {
            Status = status;
            StatusDetail = detail;
            StatusChanged?.Invoke();
        }

        // MARK: - Dictation

        public void StartRecording()
        {
            if (!LicenseManager.CanUse)
            {
                SetStatus(AppStatus.Error, "Trial expired -- buy license");
                SoundFeedback.Error();
                return;
            }

            Logger.Write("startRecording");
            AudioDimmer.Shared.Dim();
            SoundFeedback.RecordStart();
            _recorder.Start();
            SetStatus(AppStatus.Recording);
        }

        public void CancelRecording()
        {
            if (Status != AppStatus.Recording) return;
            Logger.Write("cancelRecording (short tap)");
            _recorder.Stop();
            AudioDimmer.Shared.Restore();
            SetStatus(AppStatus.Ready);
        }

        public void StopAndProcess()
        {
            Logger.Write("stopAndProcess");
            AudioDimmer.Shared.Restore();
            SoundFeedback.RecordStop();
            var wavData = _recorder.Stop();
            Logger.Write($"wav size: {wavData.Length}");
            SetStatus(AppStatus.Transcribing);

            Task.Run(async () => await Process(wavData));
        }

        private async Task Process(byte[] wavData)
        {
            var startTime = DateTime.UtcNow;
            var modeName = AppAwareMode() ?? _settings.ActivePolishMode;

            try
            {
                // Transcribe
                Logger.Write("Transcribing...");
                var rawText = await TranscriberService.Shared.Transcribe(
                    wavData, _settings.Language == "auto" ? null : _settings.Language);
                Logger.Write($"RAW: {rawText[..Math.Min(80, rawText.Length)]}...");

                if (string.IsNullOrWhiteSpace(rawText))
                {
                    SetStatus(AppStatus.Error, "No speech detected");
                    SoundFeedback.Error();
                    ScheduleReset();
                    return;
                }

                // Polish
                Logger.Write($"Polishing [{modeName}]...");
                SetStatus(AppStatus.Polishing);
                var activeMode = _modeManager.AllModes.FirstOrDefault(m => m.Id == modeName)
                    ?? PolishMode.BuiltIn[1]; // default to clean

                string polished;
                if (modeName == "raw" || activeMode.Prompt == null)
                {
                    polished = rawText;
                }
                else
                {
                    try
                    {
                        polished = await PolisherService.Shared.Polish(rawText, activeMode);
                    }
                    catch (Exception ex)
                    {
                        Logger.Write($"Polish failed: {ex.Message}, using raw text");
                        polished = rawText;
                    }
                }
                Logger.Write($"POLISHED: {polished[..Math.Min(80, polished.Length)]}...");

                // Paste
                PasteService.Paste(polished);

                // Track
                var duration = (DateTime.UtcNow - startTime).TotalSeconds;
                var wordCount = polished.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length;

                _history.Add(rawText, polished, modeName, duration);

                if (!LicenseManager.IsLicensed)
                {
                    _settings.TrialUses++;
                    _settings.Save();
                }

                SoundFeedback.Done();
                LastWordCount = wordCount;
                LastDuration = duration;
                SetStatus(AppStatus.Done);
                Logger.Write($"Done: {wordCount}w in {duration:F1}s");
                ScheduleReset();
            }
            catch (Exception ex)
            {
                Logger.Write($"ERROR: {ex.Message}");
                SoundFeedback.Error();

                var msg = ex.Message;
                if (msg.Contains("API") || msg.Contains("key"))
                    SetStatus(AppStatus.Error, "API error -- check keys in Settings");
                else if (msg.Contains("network") || msg.Contains("connection"))
                    SetStatus(AppStatus.Error, "No internet -- check connection");
                else
                    SetStatus(AppStatus.Error, msg.Length > 50 ? msg[..50] : msg);
                ScheduleReset();
            }
        }

        // MARK: - Voice Search

        public void StartSearchRecording()
        {
            if (!LicenseManager.CanUse)
            {
                SetStatus(AppStatus.Error, "Trial expired -- buy license");
                SoundFeedback.Error();
                return;
            }

            Logger.Write("startSearchRecording");
            AudioDimmer.Shared.Dim();
            SoundFeedback.RecordStart();
            _recorder.Start();
            SetStatus(AppStatus.Recording);
        }

        public void StopSearchAndProcess()
        {
            Logger.Write("stopSearchAndProcess");
            AudioDimmer.Shared.Restore();
            SoundFeedback.RecordStop();
            var wavData = _recorder.Stop();
            SetStatus(AppStatus.Transcribing);

            Task.Run(async () => await PerformSearch(wavData));
        }

        private async Task PerformSearch(byte[] wavData)
        {
            try
            {
                var query = await TranscriberService.Shared.Transcribe(
                    wavData, _settings.Language == "auto" ? null : _settings.Language);
                Logger.Write($"Search query: {query}");

                if (string.IsNullOrWhiteSpace(query))
                {
                    SetStatus(AppStatus.Error, "No speech detected");
                    return;
                }

                SetStatus(AppStatus.Polishing, "Searching...");
                var result = await SearchService.Shared.Search(query);

                SoundFeedback.Done();

                // Show search window with result on UI thread
                System.Windows.Application.Current?.Dispatcher.Invoke(() =>
                {
                    var searchWindow = new Views.SearchWindow(query, result);
                    searchWindow.Show();
                    searchWindow.Activate();
                });

                SetStatus(AppStatus.Ready);
            }
            catch (Exception ex)
            {
                Logger.Write($"Search error: {ex.Message}");
                SoundFeedback.Error();
                SetStatus(AppStatus.Error, ex.Message.Length > 50 ? ex.Message[..50] : ex.Message);
                ScheduleReset();
            }
        }

        // MARK: - App-Aware Context

        [DllImport("user32.dll")]
        private static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

        private string? AppAwareMode()
        {
            if (!_settings.AppAwareContext) return null;
            if (_settings.ActivePolishMode != "clean") return null;

            try
            {
                var hwnd = GetForegroundWindow();
                GetWindowThreadProcessId(hwnd, out uint pid);
                var process = System.Diagnostics.Process.GetProcessById((int)pid);
                var processName = process.ProcessName.ToLowerInvariant();

                var mapping = new Dictionary<string, string>
                {
                    // Chat & Messaging -> Casual
                    { "slack", "casual" },
                    { "teams", "casual" },
                    { "discord", "casual" },
                    { "whatsapp", "casual" },
                    { "telegram", "casual" },

                    // Email -> Email
                    { "outlook", "email" },
                    { "thunderbird", "email" },

                    // IDEs & Code -> Code
                    { "devenv", "coding" },      // Visual Studio
                    { "code", "coding" },         // VS Code
                    { "idea64", "coding" },       // IntelliJ
                    { "cursor", "coding" },       // Cursor

                    // Business & Docs -> Professional
                    { "winword", "professional" },
                    { "powerpnt", "professional" },
                };

                foreach (var kvp in mapping)
                {
                    if (processName.Contains(kvp.Key, StringComparison.Ordinal))
                    {
                        Logger.Write($"App-aware: {processName} -> {kvp.Value}");
                        return kvp.Value;
                    }
                }
            }
            catch (Exception ex)
            {
                Logger.Write($"App-aware detection failed: {ex.Message}");
            }

            return null;
        }

        private void ScheduleReset()
        {
            Task.Run(async () =>
            {
                await Task.Delay(6000);
                if (Status == AppStatus.Done || Status == AppStatus.Error)
                {
                    SetStatus(AppStatus.Ready);
                }
            });
        }
    }
}
