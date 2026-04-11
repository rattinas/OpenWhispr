using System;
using System.Diagnostics;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using Hardcodet.NotifyIcon.Wpf;
using Microsoft.Win32;
using TalkIsCheap.Models;
using TalkIsCheap.Services;
using TalkIsCheap.Views;

namespace TalkIsCheap
{
    public partial class App : Application
    {
        private TaskbarIcon? _notifyIcon;
        private SettingsWindow? _settingsWindow;
        private readonly AppState _state = AppState.Shared;
        private readonly AppSettings _settings = AppSettings.Shared;
        private DispatcherTimer? _statusTimer;

        protected override void OnStartup(StartupEventArgs e)
        {
            base.OnStartup(e);

            Services.Logger.Write("=== STARTUP v2.0 (Windows) ===");

            // Create system tray icon
            _notifyIcon = new TaskbarIcon
            {
                ToolTipText = "TalkIsCheap",
                ContextMenu = BuildContextMenu(),
                MenuActivation = PopupActivationMode.LeftOrRightClick
            };

            // Set initial icon
            UpdateTrayIcon();

            // Listen for status changes
            _state.StatusChanged += () =>
            {
                Dispatcher.Invoke(() =>
                {
                    UpdateTrayIcon();
                    UpdateContextMenu();
                });
            };

            // Start hotkey manager
            SetupHotkeyManager();

            // Periodic license validation
            CheckLicenseValidation();

            // Show onboarding if needed
            if (!_settings.HasCompletedOnboarding)
            {
                Dispatcher.BeginInvoke(() =>
                {
                    var onboarding = new OnboardingWindow();
                    onboarding.Show();
                    onboarding.Activate();
                });
            }

            Services.Logger.Write("Ready!");
        }

        protected override void OnExit(ExitEventArgs e)
        {
            HotkeyManager.Shared.Dispose();
            _notifyIcon?.Dispose();
            base.OnExit(e);
        }

        // MARK: - Hotkey Manager Setup

        private void SetupHotkeyManager()
        {
            var hotkey = HotkeyManager.Shared;

            hotkey.OnKeyDown = () =>
            {
                Services.Logger.Write("KEY DOWN");
                Dispatcher.Invoke(() => _state.StartRecording());
            };

            hotkey.OnKeyUp = () =>
            {
                Services.Logger.Write("KEY UP");
                Dispatcher.Invoke(() =>
                {
                    if (_state.IsRecording) _state.StopAndProcess();
                });
            };

            hotkey.OnCancel = () =>
            {
                Services.Logger.Write("KEY CANCEL (short tap)");
                Dispatcher.Invoke(() => _state.CancelRecording());
            };

            hotkey.OnSearchKeyDown = () =>
            {
                Services.Logger.Write("SEARCH KEY DOWN");
                Dispatcher.Invoke(() => _state.StartSearchRecording());
            };

            hotkey.OnSearchKeyUp = () =>
            {
                Services.Logger.Write("SEARCH KEY UP");
                Dispatcher.Invoke(() =>
                {
                    if (_state.IsRecording) _state.StopSearchAndProcess();
                });
            };

            hotkey.Start();
        }

        // MARK: - Tray Icon

        private void UpdateTrayIcon()
        {
            if (_notifyIcon == null) return;

            var tooltip = _state.StatusText;
            _notifyIcon.ToolTipText = $"TalkIsCheap - {tooltip}";
        }

        // MARK: - Context Menu

        private ContextMenu BuildContextMenu()
        {
            var menu = new ContextMenu();

            // Status
            var statusItem = new MenuItem
            {
                Header = _state.StatusText,
                IsEnabled = false,
                FontWeight = FontWeights.SemiBold
            };
            menu.Items.Add(statusItem);

            menu.Items.Add(new Separator());

            // Polish Mode submenu
            var modeMenu = new MenuItem { Header = GetActiveModeLabel() };
            foreach (var mode in PolishMode.BuiltIn)
            {
                var item = new MenuItem
                {
                    Header = $"{mode.Emoji} {mode.Label}",
                    IsChecked = _settings.ActivePolishMode == mode.Id
                };
                var modeId = mode.Id;
                item.Click += (s, e) =>
                {
                    _settings.ActivePolishMode = modeId;
                    _settings.Save();
                    UpdateContextMenu();
                };
                modeMenu.Items.Add(item);
            }

            var customModes = PolishModeManager.Shared.CustomModes;
            if (customModes.Count > 0)
            {
                modeMenu.Items.Add(new Separator());
                foreach (var mode in customModes)
                {
                    var item = new MenuItem
                    {
                        Header = $"* {mode.Label}",
                        IsChecked = _settings.ActivePolishMode == mode.Id
                    };
                    var modeId = mode.Id;
                    item.Click += (s, e) =>
                    {
                        _settings.ActivePolishMode = modeId;
                        _settings.Save();
                        UpdateContextMenu();
                    };
                    modeMenu.Items.Add(item);
                }
            }
            menu.Items.Add(modeMenu);

            // Quick stats
            var history = TranscriptionHistory.Shared;
            if (history.TotalCount > 0)
            {
                var statsItem = new MenuItem
                {
                    Header = $"{history.TodayWordCount} words today | {history.TotalCount} total",
                    IsEnabled = false,
                    FontSize = 11
                };
                menu.Items.Add(statsItem);
            }

            menu.Items.Add(new Separator());

            // Voice Search hint or trial warning
            if (!LicenseManager.CanUse)
            {
                var trialItem = new MenuItem
                {
                    Header = "Trial expired",
                    IsEnabled = false,
                    Foreground = Brushes.OrangeRed
                };
                menu.Items.Add(trialItem);

                var buyItem = new MenuItem { Header = "Buy License -- $19" };
                buyItem.Click += (s, e) =>
                    Process.Start(new ProcessStartInfo("https://talkischeap.app/checkout") { UseShellExecute = true });
                menu.Items.Add(buyItem);
            }
            else
            {
                var searchHint = new MenuItem
                {
                    Header = "Voice Search: double-tap your hotkey",
                    IsEnabled = false,
                    FontSize = 11
                };
                menu.Items.Add(searchHint);
            }

            menu.Items.Add(new Separator());

            // Open File
            var openFile = new MenuItem { Header = "Open File..." };
            openFile.Click += OpenFile_Click;
            openFile.IsEnabled = LicenseManager.CanUse;
            menu.Items.Add(openFile);

            // Settings
            var settingsItem = new MenuItem { Header = "Settings" };
            settingsItem.Click += (s, e) => ShowSettings();
            menu.Items.Add(settingsItem);

            menu.Items.Add(new Separator());

            // Toggles
            var dimToggle = new MenuItem
            {
                Header = "Dim audio while recording",
                IsChecked = _settings.DimAudioWhileRecording,
                IsCheckable = true
            };
            dimToggle.Checked += (s, e) => { _settings.DimAudioWhileRecording = true; _settings.Save(); };
            dimToggle.Unchecked += (s, e) => { _settings.DimAudioWhileRecording = false; _settings.Save(); };
            menu.Items.Add(dimToggle);

            var appAwareToggle = new MenuItem
            {
                Header = "App-aware context",
                IsChecked = _settings.AppAwareContext,
                IsCheckable = true
            };
            appAwareToggle.Checked += (s, e) => { _settings.AppAwareContext = true; _settings.Save(); };
            appAwareToggle.Unchecked += (s, e) => { _settings.AppAwareContext = false; _settings.Save(); };
            menu.Items.Add(appAwareToggle);

            menu.Items.Add(new Separator());

            // Provider info
            var providerInfo = new MenuItem
            {
                Header = $"{(_settings.SttProvider == "groq" ? "Groq" : "Local")} -> {(_settings.PolishProvider == "anthropic" ? "Claude" : "Ollama")}  |  {(LicenseManager.IsLicensed ? "Licensed" : $"{_settings.RemainingTrial} left")}",
                IsEnabled = false,
                FontSize = 11
            };
            menu.Items.Add(providerInfo);

            menu.Items.Add(new Separator());

            // Quit
            var quitItem = new MenuItem { Header = "Quit TalkIsCheap" };
            quitItem.Click += (s, e) =>
            {
                _notifyIcon?.Dispose();
                Shutdown();
            };
            menu.Items.Add(quitItem);

            return menu;
        }

        private void UpdateContextMenu()
        {
            if (_notifyIcon != null)
            {
                _notifyIcon.ContextMenu = BuildContextMenu();
            }
        }

        private string GetActiveModeLabel()
        {
            var mode = PolishModeManager.Shared.AllModes
                .FirstOrDefault(m => m.Id == _settings.ActivePolishMode);
            return mode != null ? $"{mode.Emoji} {mode.Label}" : "Clean";
        }

        // MARK: - Actions

        private void ShowSettings()
        {
            if (_settingsWindow == null || !_settingsWindow.IsLoaded)
            {
                _settingsWindow = new SettingsWindow();
                _settingsWindow.Closed += (s, e) => _settingsWindow = null;
            }
            _settingsWindow.Show();
            _settingsWindow.Activate();
        }

        private void OpenFile_Click(object sender, RoutedEventArgs e)
        {
            var dialog = new OpenFileDialog
            {
                Title = "Choose audio, video, or PDF file",
                Filter = "Supported files|*.mp3;*.wav;*.m4a;*.ogg;*.flac;*.mp4;*.mov;*.avi;*.mkv;*.webm;*.pdf|All files|*.*"
            };

            if (dialog.ShowDialog() == true)
            {
                var filePath = dialog.FileName;
                Task.Run(async () =>
                {
                    try
                    {
                        var transcript = await FileTranscriptionService.Shared.Transcribe(filePath);
                        var summary = await FileTranscriptionService.Shared.Summarize(transcript);

                        Dispatcher.Invoke(() =>
                        {
                            var text = string.IsNullOrEmpty(summary) ? transcript : $"{summary}\n\n---\n\n{transcript}";
                            Clipboard.SetText(text);
                            MessageBox.Show(
                                $"Transcription complete!\n\n{text[..Math.Min(500, text.Length)]}...\n\n(Full text copied to clipboard)",
                                "TalkIsCheap - File Transcription",
                                MessageBoxButton.OK,
                                MessageBoxImage.Information);
                        });
                    }
                    catch (Exception ex)
                    {
                        Dispatcher.Invoke(() =>
                        {
                            MessageBox.Show($"Transcription failed: {ex.Message}",
                                "TalkIsCheap - Error",
                                MessageBoxButton.OK,
                                MessageBoxImage.Error);
                        });
                    }
                });
            }
        }

        // MARK: - License Validation

        private void CheckLicenseValidation()
        {
            if (!LicenseManager.IsLicensed) return;

            var lastCheck = _settings.LastValidationCheck;
            var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
            var sevenDays = 7 * 86400;

            if (now - lastCheck <= sevenDays) return;

            Task.Run(async () =>
            {
                var valid = await LicenseManager.ValidateOnline();
                if (valid.HasValue)
                {
                    if (valid.Value)
                    {
                        _settings.LastValidationCheck = now;
                        _settings.Save();
                        Services.Logger.Write("License validation: OK");
                    }
                    else
                    {
                        Services.Logger.Write("License validation: INVALID -- clearing activation");
                        _settings.ActivationToken = "";
                        _settings.ActivatedAt = "";
                        _settings.Save();
                    }
                }
                else
                {
                    Services.Logger.Write("License validation: network unreachable, skipping");
                }
            });
        }
    }
}
