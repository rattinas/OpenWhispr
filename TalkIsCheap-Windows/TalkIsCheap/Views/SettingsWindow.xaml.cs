using System;
using System.Diagnostics;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using TalkIsCheap.Models;
using TalkIsCheap.Services;

namespace TalkIsCheap.Views
{
    public partial class SettingsWindow : Window
    {
        private readonly AppSettings _settings = AppSettings.Shared;
        private bool _isCapturingHotkey;
        private bool _isLoading = true;

        public SettingsWindow()
        {
            InitializeComponent();
            LoadSettings();
            RefreshLicenseUI();
            _isLoading = false;
        }

        private void LoadSettings()
        {
            // STT Provider
            foreach (ComboBoxItem item in SttProviderCombo.Items)
            {
                if (item.Tag?.ToString() == _settings.SttProvider)
                {
                    SttProviderCombo.SelectedItem = item;
                    break;
                }
            }

            // Language
            LanguageCombo.Items.Clear();
            foreach (var lang in AppSettings.Languages)
            {
                var item = new ComboBoxItem { Content = lang.Name, Tag = lang.Code };
                LanguageCombo.Items.Add(item);
                if (lang.Code == _settings.Language)
                    LanguageCombo.SelectedItem = item;
            }

            // Polish Provider
            foreach (ComboBoxItem item in PolishProviderCombo.Items)
            {
                if (item.Tag?.ToString() == _settings.PolishProvider)
                {
                    PolishProviderCombo.SelectedItem = item;
                    break;
                }
            }

            // Search Model
            foreach (ComboBoxItem item in SearchModelCombo.Items)
            {
                if (item.Tag?.ToString() == _settings.SearchModel)
                {
                    SearchModelCombo.SelectedItem = item;
                    break;
                }
            }

            // API Keys
            GroqKeyBox.Password = _settings.GroqApiKey;
            AnthropicKeyBox.Password = _settings.AnthropicApiKey;
            BraveKeyBox.Password = _settings.BraveApiKey;

            // Hotkey
            HotkeyDisplay.Text = _settings.HotkeyShort;
        }

        private void RefreshLicenseUI()
        {
            LicenseStatusPanel.Children.Clear();

            if (LicenseManager.IsLicensed)
            {
                var sp = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 4, 0, 4) };
                sp.Children.Add(new TextBlock { Text = "Licensed", FontWeight = FontWeights.Bold,
                    Foreground = Brushes.Green, FontSize = 16, VerticalAlignment = VerticalAlignment.Center });
                LicenseStatusPanel.Children.Add(sp);

                var keyText = new TextBlock
                {
                    Text = $"Key: {_settings.LicenseKey}",
                    FontFamily = new FontFamily("Consolas"),
                    Foreground = Brushes.Gray,
                    FontSize = 11,
                    Margin = new Thickness(0, 4, 0, 0)
                };
                LicenseStatusPanel.Children.Add(keyText);

                var hwidText = new TextBlock
                {
                    Text = $"Machine ID: {LicenseManager.HardwareId()[..Math.Min(12, LicenseManager.HardwareId().Length)]}...",
                    FontFamily = new FontFamily("Consolas"),
                    Foreground = Brushes.Gray,
                    FontSize = 11,
                    Margin = new Thickness(0, 2, 0, 0)
                };
                LicenseStatusPanel.Children.Add(hwidText);

                ActivateHeader.Visibility = Visibility.Collapsed;
                LicenseKeyBox.Visibility = Visibility.Collapsed;
                ActivateBtn.Visibility = Visibility.Collapsed;
                DeactivateBtn.Visibility = Visibility.Visible;
            }
            else if (_settings.RemainingTrial > 0)
            {
                var sp = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 4, 0, 4) };
                sp.Children.Add(new TextBlock { Text = "Free Trial", FontWeight = FontWeights.Bold,
                    Foreground = Brushes.Orange, FontSize = 16, VerticalAlignment = VerticalAlignment.Center });
                LicenseStatusPanel.Children.Add(sp);

                LicenseStatusPanel.Children.Add(new TextBlock
                {
                    Text = $"{_settings.RemainingTrial} of {AppSettings.TrialLimit} uses remaining",
                    Foreground = Brushes.Gray,
                    FontSize = 12
                });

                ActivateHeader.Visibility = Visibility.Visible;
                LicenseKeyBox.Visibility = Visibility.Visible;
                ActivateBtn.Visibility = Visibility.Visible;
                DeactivateBtn.Visibility = Visibility.Collapsed;
            }
            else
            {
                var sp = new StackPanel { Margin = new Thickness(0, 4, 0, 4) };
                sp.Children.Add(new TextBlock { Text = "Trial Expired", FontWeight = FontWeights.Bold,
                    Foreground = Brushes.Red, FontSize = 16 });
                sp.Children.Add(new TextBlock { Text = "Purchase a license to continue using TalkIsCheap",
                    Foreground = Brushes.Gray, FontSize = 12 });
                LicenseStatusPanel.Children.Add(sp);

                ActivateHeader.Visibility = Visibility.Visible;
                LicenseKeyBox.Visibility = Visibility.Visible;
                ActivateBtn.Visibility = Visibility.Visible;
                DeactivateBtn.Visibility = Visibility.Collapsed;
            }
        }

        // Event handlers
        private void SttProvider_Changed(object sender, SelectionChangedEventArgs e)
        {
            if (_isLoading) return;
            if (SttProviderCombo.SelectedItem is ComboBoxItem item)
            {
                _settings.SttProvider = item.Tag?.ToString() ?? "groq";
                _settings.Save();
            }
        }

        private void Language_Changed(object sender, SelectionChangedEventArgs e)
        {
            if (_isLoading) return;
            if (LanguageCombo.SelectedItem is ComboBoxItem item)
            {
                _settings.Language = item.Tag?.ToString() ?? "de";
                _settings.Save();
            }
        }

        private void PolishProvider_Changed(object sender, SelectionChangedEventArgs e)
        {
            if (_isLoading) return;
            if (PolishProviderCombo.SelectedItem is ComboBoxItem item)
            {
                _settings.PolishProvider = item.Tag?.ToString() ?? "anthropic";
                _settings.Save();
            }
        }

        private void SearchModel_Changed(object sender, SelectionChangedEventArgs e)
        {
            if (_isLoading) return;
            if (SearchModelCombo.SelectedItem is ComboBoxItem item)
            {
                _settings.SearchModel = item.Tag?.ToString() ?? "claude-sonnet-4-6";
                _settings.Save();
            }
        }

        private void GroqKey_Changed(object sender, RoutedEventArgs e)
        {
            if (_isLoading) return;
            _settings.GroqApiKey = GroqKeyBox.Password;
            _settings.Save();
        }

        private void AnthropicKey_Changed(object sender, RoutedEventArgs e)
        {
            if (_isLoading) return;
            _settings.AnthropicApiKey = AnthropicKeyBox.Password;
            _settings.Save();
        }

        private void BraveKey_Changed(object sender, RoutedEventArgs e)
        {
            if (_isLoading) return;
            _settings.BraveApiKey = BraveKeyBox.Password;
            _settings.Save();
        }

        private void ChangeHotkey_Click(object sender, RoutedEventArgs e)
        {
            if (_isCapturingHotkey) return;
            _isCapturingHotkey = true;
            ChangeHotkeyBtn.Content = "Press a key...";
            PreviewKeyDown += CaptureHotkey;
        }

        private void CaptureHotkey(object sender, KeyEventArgs e)
        {
            if (!_isCapturingHotkey) return;

            int vkCode;
            string name;

            switch (e.Key)
            {
                case Key.LeftCtrl:
                case Key.RightCtrl:
                    vkCode = 163; // Right Ctrl
                    name = "Ctrl";
                    break;
                case Key.F5:
                    vkCode = 116;
                    name = "F5";
                    break;
                case Key.F6:
                    vkCode = 117;
                    name = "F6";
                    break;
                case Key.F8:
                    vkCode = 119;
                    name = "F8";
                    break;
                default:
                    return; // ignore unsupported keys
            }

            _settings.HotkeyCode = vkCode;
            _settings.Save();
            HotkeyDisplay.Text = name;
            _isCapturingHotkey = false;
            ChangeHotkeyBtn.Content = "Change";
            PreviewKeyDown -= CaptureHotkey;
            e.Handled = true;
        }

        private async void Activate_Click(object sender, RoutedEventArgs e)
        {
            var key = LicenseKeyBox.Text.Trim();
            if (string.IsNullOrEmpty(key)) return;

            ActivateBtn.IsEnabled = false;
            ActivateBtn.Content = "Activating...";
            ActivationMessage.Text = "";

            var result = await LicenseManager.Activate(key);

            switch (result.Result)
            {
                case ActivationResult.Success:
                    ActivationMessage.Text = "License activated!";
                    ActivationMessage.Foreground = Brushes.Green;
                    LicenseKeyBox.Text = "";
                    break;
                case ActivationResult.AlreadyActivated:
                    ActivationMessage.Text = "License re-activated!";
                    ActivationMessage.Foreground = Brushes.Green;
                    LicenseKeyBox.Text = "";
                    break;
                case ActivationResult.InvalidKey:
                    ActivationMessage.Text = "Invalid license key.";
                    ActivationMessage.Foreground = Brushes.Red;
                    break;
                case ActivationResult.MaxReached:
                    ActivationMessage.Text = result.Message;
                    ActivationMessage.Foreground = Brushes.Red;
                    break;
                case ActivationResult.Revoked:
                    ActivationMessage.Text = "This license has been revoked.";
                    ActivationMessage.Foreground = Brushes.Red;
                    break;
                case ActivationResult.NetworkError:
                    ActivationMessage.Text = $"Connection error: {result.Message}";
                    ActivationMessage.Foreground = Brushes.Red;
                    break;
            }

            ActivateBtn.IsEnabled = true;
            ActivateBtn.Content = "Activate";
            RefreshLicenseUI();
        }

        private async void Deactivate_Click(object sender, RoutedEventArgs e)
        {
            DeactivateBtn.IsEnabled = false;
            DeactivateBtn.Content = "Deactivating...";

            var success = await LicenseManager.Deactivate();

            if (!success)
            {
                ActivationMessage.Text = "Failed to deactivate. Check your internet connection.";
                ActivationMessage.Foreground = Brushes.Red;
            }

            DeactivateBtn.IsEnabled = true;
            DeactivateBtn.Content = "Deactivate this PC";
            RefreshLicenseUI();
        }

        private void Buy_Click(object sender, RoutedEventArgs e)
        {
            Process.Start(new ProcessStartInfo("https://talkischeap.app/checkout") { UseShellExecute = true });
        }

        private void Hyperlink_Navigate(object sender, System.Windows.Navigation.RequestNavigateEventArgs e)
        {
            Process.Start(new ProcessStartInfo(e.Uri.AbsoluteUri) { UseShellExecute = true });
            e.Handled = true;
        }
    }
}
