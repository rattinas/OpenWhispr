using System;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using TalkIsCheap.Models;

namespace TalkIsCheap.Views
{
    public partial class OnboardingWindow : Window
    {
        private readonly AppSettings _settings = AppSettings.Shared;
        private int _step = 0;
        private const int TotalSteps = 8;

        // Fields for capturing input
        private PasswordBox? _groqKeyBox;
        private PasswordBox? _anthropicKeyBox;
        private ComboBox? _languageCombo;

        public OnboardingWindow()
        {
            InitializeComponent();
            ShowStep(0);
        }

        private void ShowStep(int step)
        {
            _step = step;
            ContentPanel.Children.Clear();

            // Update progress bar
            ProgressBar.Width = (ActualWidth > 0 ? ActualWidth : 520) * (_step + 1.0) / TotalSteps;

            switch (_step)
            {
                case 0: BuildWelcome(); break;
                case 1: BuildPermissions(); break;
                case 2: BuildSpeechEngine(); break;
                case 3: BuildPolishEngine(); break;
                case 4: BuildLanguage(); break;
                case 5: BuildHowToDictate(); break;
                case 6: BuildPolishModes(); break;
                case 7: BuildReady(); break;
            }
        }

        // Step 1: Welcome
        private void BuildWelcome()
        {
            AddCentered("\U0001F3A4", 64);
            AddCenteredText("TalkIsCheap", 28, FontWeights.Bold);
            AddCenteredText("Your voice -- polished and pasted.", 16, FontWeights.Normal, Brushes.Gray);
            AddSpacer(16);

            AddBullet("\u2328  Hold a key, speak, release");
            AddBullet("\u2728  AI cleans up your text instantly");
            AddBullet("\U0001F4CB  Auto-pasted wherever your cursor is");

            AddSpacer(12);
            AddCenteredText("50 free uses included. No credit card needed.", 11, FontWeights.Normal, Brushes.LightGray);

            NextButton.Content = "Let's set up";
        }

        // Step 2: Permissions
        private void BuildPermissions()
        {
            AddStepHeader("Permissions", "Windows handles permissions automatically");
            AddSpacer(24);

            AddCentered("\u2705", 48);
            AddCenteredText("All set!", 20, FontWeights.SemiBold, Brushes.Green);
            AddSpacer(8);
            AddCenteredText("Windows doesn't require special permission grants.\nMicrophone and keyboard access work out of the box.", 12, FontWeights.Normal, Brushes.Gray);

            NextButton.Content = "Continue";
        }

        // Step 3: Speech Engine
        private void BuildSpeechEngine()
        {
            AddStepHeader("Speech Recognition", "Choose how TalkIsCheap hears you");
            AddSpacer(8);

            AddCenteredText("Groq Cloud is the recommended engine for Windows.\nFree API key, blazing fast, highly accurate.", 12, FontWeights.Normal, Brushes.Gray);
            AddSpacer(12);

            ContentPanel.Children.Add(new TextBlock
            {
                Text = "Groq API Key",
                FontWeight = FontWeights.SemiBold,
                FontSize = 12,
                Margin = new Thickness(0, 8, 0, 4)
            });

            _groqKeyBox = new PasswordBox { Password = _settings.GroqApiKey };
            _groqKeyBox.PasswordChanged += (s, e) =>
            {
                _settings.GroqApiKey = _groqKeyBox.Password;
                _settings.Save();
            };
            ContentPanel.Children.Add(_groqKeyBox);

            var link = new TextBlock { FontSize = 11, Margin = new Thickness(0, 4, 0, 0) };
            var hl = new Hyperlink(new Run("Get free key at console.groq.com"))
            {
                NavigateUri = new Uri("https://console.groq.com/keys")
            };
            hl.RequestNavigate += (s, e) =>
            {
                Process.Start(new ProcessStartInfo(e.Uri.AbsoluteUri) { UseShellExecute = true });
                e.Handled = true;
            };
            link.Inlines.Add(hl);
            ContentPanel.Children.Add(link);

            NextButton.Content = "Continue";
        }

        // Step 4: Polish Engine
        private void BuildPolishEngine()
        {
            AddStepHeader("Text Polishing", "AI cleans up grammar, removes filler words, and formats your text");
            AddSpacer(8);

            AddCenteredText("Anthropic Claude provides best quality.\nCost: ~$0.001 per dictation.", 12, FontWeights.Normal, Brushes.Gray);
            AddSpacer(12);

            ContentPanel.Children.Add(new TextBlock
            {
                Text = "Anthropic API Key",
                FontWeight = FontWeights.SemiBold,
                FontSize = 12,
                Margin = new Thickness(0, 8, 0, 4)
            });

            _anthropicKeyBox = new PasswordBox { Password = _settings.AnthropicApiKey };
            _anthropicKeyBox.PasswordChanged += (s, e) =>
            {
                _settings.AnthropicApiKey = _anthropicKeyBox.Password;
                _settings.Save();
            };
            ContentPanel.Children.Add(_anthropicKeyBox);

            var link = new TextBlock { FontSize = 11, Margin = new Thickness(0, 4, 0, 0) };
            var hl = new Hyperlink(new Run("Get key at console.anthropic.com"))
            {
                NavigateUri = new Uri("https://console.anthropic.com/settings/keys")
            };
            hl.RequestNavigate += (s, e) =>
            {
                Process.Start(new ProcessStartInfo(e.Uri.AbsoluteUri) { UseShellExecute = true });
                e.Handled = true;
            };
            link.Inlines.Add(hl);
            ContentPanel.Children.Add(link);

            NextButton.Content = "Continue";
        }

        // Step 5: Language
        private void BuildLanguage()
        {
            AddStepHeader("Language", "Pick your primary language or let TalkIsCheap auto-detect");
            AddSpacer(12);

            _languageCombo = new ComboBox { Margin = new Thickness(0, 0, 0, 8) };
            foreach (var lang in AppSettings.Languages)
            {
                var item = new ComboBoxItem { Content = lang.Name, Tag = lang.Code };
                _languageCombo.Items.Add(item);
                if (lang.Code == _settings.Language)
                    _languageCombo.SelectedItem = item;
            }
            _languageCombo.SelectionChanged += (s, e) =>
            {
                if (_languageCombo.SelectedItem is ComboBoxItem item)
                {
                    _settings.Language = item.Tag?.ToString() ?? "de";
                    _settings.Save();
                }
            };
            ContentPanel.Children.Add(_languageCombo);

            AddCenteredText("You can switch languages anytime from Settings.\nTalkIsCheap also supports mixing languages mid-sentence.", 11, FontWeights.Normal, Brushes.LightGray);

            NextButton.Content = "Continue";
        }

        // Step 6: How to Dictate
        private void BuildHowToDictate()
        {
            AddStepHeader("How to Dictate", "Three ways to use your voice");
            AddSpacer(12);

            AddHotkeyCard("Hold Hotkey", "Push-to-Talk",
                "Hold the key, speak, release. Text appears at your cursor.", "#0078D7");
            AddHotkeyCard("Hotkey + Shift", "Hands-Free Mode",
                "Hold both keys to start, release when done. For longer dictation.", "#8B5CF6");
            AddHotkeyCard("Double-tap", "Voice Search",
                "Tap your hotkey twice, ask a question. AI searches the web and answers.", "#FF8C00");

            NextButton.Content = "Continue";
        }

        // Step 7: Polish Modes
        private void BuildPolishModes()
        {
            AddStepHeader("Polish Modes", "Choose how your text gets cleaned up");
            AddSpacer(8);

            var grid = new WrapPanel { Orientation = Orientation.Horizontal };
            foreach (var mode in PolishMode.BuiltIn)
            {
                var isSelected = _settings.ActivePolishMode == mode.Id;
                var border = new Border
                {
                    Background = isSelected ? new SolidColorBrush(Color.FromArgb(25, 0, 120, 215)) : Brushes.WhiteSmoke,
                    BorderBrush = isSelected ? new SolidColorBrush(Color.FromRgb(0, 120, 215)) : Brushes.Transparent,
                    BorderThickness = new Thickness(1.5),
                    CornerRadius = new CornerRadius(6),
                    Padding = new Thickness(8, 6, 8, 6),
                    Margin = new Thickness(2),
                    Width = 210,
                    Cursor = System.Windows.Input.Cursors.Hand
                };

                var sp = new StackPanel { Orientation = Orientation.Horizontal };
                sp.Children.Add(new TextBlock { Text = mode.Emoji, FontSize = 16, Margin = new Thickness(0, 0, 6, 0) });

                var textSp = new StackPanel();
                textSp.Children.Add(new TextBlock { Text = mode.Label, FontWeight = FontWeights.SemiBold, FontSize = 12 });
                textSp.Children.Add(new TextBlock
                {
                    Text = GetModeDescription(mode.Id),
                    FontSize = 10,
                    Foreground = Brushes.Gray,
                    TextTrimming = TextTrimming.CharacterEllipsis
                });
                sp.Children.Add(textSp);
                border.Child = sp;

                var modeId = mode.Id;
                border.MouseLeftButtonUp += (s, e) =>
                {
                    _settings.ActivePolishMode = modeId;
                    _settings.Save();
                    ShowStep(_step); // refresh
                };

                grid.Children.Add(border);
            }
            ContentPanel.Children.Add(grid);

            AddSpacer(8);
            AddCenteredText("Switch modes anytime from the menu bar.\nCreate unlimited custom modes in Settings.", 11, FontWeights.Normal, Brushes.LightGray);

            NextButton.Content = "Continue";
        }

        // Step 8: Ready
        private void BuildReady()
        {
            AddCentered("\u2705", 64);
            AddCenteredText("You're all set!", 24, FontWeights.Bold);
            AddSpacer(8);
            AddCenteredText("Quick Reference", 12, FontWeights.SemiBold, Brushes.Gray);
            AddSpacer(8);

            var refPanel = new StackPanel
            {
                Background = new SolidColorBrush(Color.FromRgb(248, 248, 248)),
                Margin = new Thickness(0, 0, 0, 8)
            };
            refPanel.Children.Add(MakeRefRow("Hold Hotkey", "Dictate (push-to-talk)"));
            refPanel.Children.Add(MakeRefRow("Hotkey+Shift", "Hands-free dictation"));
            refPanel.Children.Add(MakeRefRow("2x Hotkey", "Voice Search"));
            refPanel.Children.Add(MakeRefRow("Menu bar icon", "Settings, modes, history"));

            var border = new Border
            {
                Child = refPanel,
                CornerRadius = new CornerRadius(8),
                Padding = new Thickness(12),
                Background = new SolidColorBrush(Color.FromRgb(248, 248, 248))
            };
            ContentPanel.Children.Add(border);

            AddSpacer(8);
            AddCenteredText("You have 50 free trial uses.", 11, FontWeights.Normal, Brushes.Gray);

            NextButton.Content = "Start Using TalkIsCheap";
        }

        private void Next_Click(object sender, RoutedEventArgs e)
        {
            if (_step >= TotalSteps - 1)
            {
                _settings.HasCompletedOnboarding = true;
                _settings.Save();
                Close();
                return;
            }
            ShowStep(_step + 1);
        }

        // Helper methods
        private void AddStepHeader(string title, string subtitle)
        {
            ContentPanel.Children.Add(new TextBlock
            {
                Text = title,
                FontSize = 20,
                FontWeight = FontWeights.Bold,
                HorizontalAlignment = HorizontalAlignment.Center,
                Margin = new Thickness(0, 0, 0, 4)
            });
            ContentPanel.Children.Add(new TextBlock
            {
                Text = subtitle,
                FontSize = 13,
                Foreground = Brushes.Gray,
                HorizontalAlignment = HorizontalAlignment.Center,
                TextWrapping = TextWrapping.Wrap,
                TextAlignment = TextAlignment.Center,
                Margin = new Thickness(0, 0, 0, 8)
            });
        }

        private void AddCentered(string text, double fontSize)
        {
            ContentPanel.Children.Add(new TextBlock
            {
                Text = text,
                FontSize = fontSize,
                HorizontalAlignment = HorizontalAlignment.Center,
                Margin = new Thickness(0, 4, 0, 4)
            });
        }

        private void AddCenteredText(string text, double fontSize, FontWeight weight,
            Brush? foreground = null)
        {
            ContentPanel.Children.Add(new TextBlock
            {
                Text = text,
                FontSize = fontSize,
                FontWeight = weight,
                Foreground = foreground ?? Brushes.Black,
                HorizontalAlignment = HorizontalAlignment.Center,
                TextAlignment = TextAlignment.Center,
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 2, 0, 2)
            });
        }

        private void AddBullet(string text)
        {
            ContentPanel.Children.Add(new TextBlock
            {
                Text = text,
                FontSize = 14,
                Margin = new Thickness(24, 4, 24, 4)
            });
        }

        private void AddSpacer(double height)
        {
            ContentPanel.Children.Add(new Border { Height = height });
        }

        private void AddHotkeyCard(string keys, string title, string desc, string colorHex)
        {
            var color = (Color)ColorConverter.ConvertFromString(colorHex);
            var brush = new SolidColorBrush(color);

            var border = new Border
            {
                Background = new SolidColorBrush(Color.FromRgb(250, 250, 250)),
                CornerRadius = new CornerRadius(8),
                Padding = new Thickness(12),
                Margin = new Thickness(0, 4, 0, 4)
            };

            var sp = new StackPanel { Orientation = Orientation.Horizontal };

            var keyBorder = new Border
            {
                Background = new SolidColorBrush(Color.FromArgb(25, color.R, color.G, color.B)),
                CornerRadius = new CornerRadius(4),
                Padding = new Thickness(8, 4, 8, 4),
                Width = 110
            };
            keyBorder.Child = new TextBlock
            {
                Text = keys,
                FontFamily = new FontFamily("Consolas"),
                FontSize = 11,
                FontWeight = FontWeights.Bold,
                Foreground = brush,
                HorizontalAlignment = HorizontalAlignment.Center
            };
            sp.Children.Add(keyBorder);

            var textSp = new StackPanel { Margin = new Thickness(12, 0, 0, 0) };
            textSp.Children.Add(new TextBlock { Text = title, FontWeight = FontWeights.SemiBold, FontSize = 13 });
            textSp.Children.Add(new TextBlock { Text = desc, FontSize = 11, Foreground = Brushes.Gray, TextWrapping = TextWrapping.Wrap });
            sp.Children.Add(textSp);

            border.Child = sp;
            ContentPanel.Children.Add(border);
        }

        private StackPanel MakeRefRow(string keys, string action)
        {
            var sp = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 3, 0, 3) };

            var keyBorder = new Border
            {
                Background = new SolidColorBrush(Color.FromRgb(230, 230, 230)),
                CornerRadius = new CornerRadius(3),
                Padding = new Thickness(6, 2, 6, 2),
                Width = 110
            };
            keyBorder.Child = new TextBlock
            {
                Text = keys,
                FontFamily = new FontFamily("Consolas"),
                FontSize = 11,
                FontWeight = FontWeights.SemiBold
            };
            sp.Children.Add(keyBorder);

            sp.Children.Add(new TextBlock
            {
                Text = action,
                FontSize = 11,
                Foreground = Brushes.Gray,
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(8, 0, 0, 0)
            });

            return sp;
        }

        private static string GetModeDescription(string id)
        {
            return id switch
            {
                "raw" => "Exact transcription, no changes",
                "clean" => "Fix punctuation & filler words",
                "professional" => "Business communication",
                "marketing" => "Punchy, benefit-driven copy",
                "email" => "Structured email format",
                "coding" => "Technical documentation",
                "casual" => "Chat message style",
                "claude_prompt" => "Generate Claude AI prompts",
                "chatgpt_prompt" => "Generate ChatGPT prompts",
                _ => ""
            };
        }
    }
}
