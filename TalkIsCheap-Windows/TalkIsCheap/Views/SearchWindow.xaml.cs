using System;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using TalkIsCheap.Services;

namespace TalkIsCheap.Views
{
    public partial class SearchWindow : Window
    {
        private readonly SearchResult _result;

        public SearchWindow(string query, SearchResult result)
        {
            InitializeComponent();
            _result = result;

            QueryText.Text = query;
            AnswerText.Text = result.Answer;

            // Build sources list
            if (result.Sources.Count > 0)
            {
                var header = new TextBlock
                {
                    Text = "Sources",
                    FontWeight = FontWeights.SemiBold,
                    FontSize = 12,
                    Foreground = Brushes.Gray,
                    Margin = new Thickness(0, 0, 0, 8)
                };
                SourcesPanel.Children.Add(header);

                for (int i = 0; i < result.Sources.Count; i++)
                {
                    var source = result.Sources[i];
                    var border = new Border
                    {
                        Background = new SolidColorBrush(Color.FromRgb(248, 248, 248)),
                        CornerRadius = new CornerRadius(6),
                        Padding = new Thickness(10, 8, 10, 8),
                        Margin = new Thickness(0, 2, 0, 2),
                        Cursor = Cursors.Hand
                    };

                    var sp = new StackPanel { Orientation = Orientation.Horizontal };

                    var numBorder = new Border
                    {
                        Background = new SolidColorBrush(Color.FromArgb(25, 230, 80, 50)),
                        CornerRadius = new CornerRadius(4),
                        Width = 24,
                        Height = 24,
                        Margin = new Thickness(0, 0, 8, 0)
                    };
                    numBorder.Child = new TextBlock
                    {
                        Text = (i + 1).ToString(),
                        FontSize = 11,
                        FontWeight = FontWeights.Bold,
                        Foreground = new SolidColorBrush(Color.FromRgb(230, 80, 50)),
                        HorizontalAlignment = HorizontalAlignment.Center,
                        VerticalAlignment = VerticalAlignment.Center
                    };
                    sp.Children.Add(numBorder);

                    var textSp = new StackPanel();
                    textSp.Children.Add(new TextBlock
                    {
                        Text = source.Title,
                        FontSize = 11,
                        FontWeight = FontWeights.Medium,
                        TextTrimming = TextTrimming.CharacterEllipsis,
                        MaxWidth = 450
                    });

                    try
                    {
                        var uri = new Uri(source.Url);
                        textSp.Children.Add(new TextBlock
                        {
                            Text = uri.Host,
                            FontSize = 9,
                            Foreground = Brushes.LightGray
                        });
                    }
                    catch
                    {
                        textSp.Children.Add(new TextBlock
                        {
                            Text = source.Url,
                            FontSize = 9,
                            Foreground = Brushes.LightGray,
                            TextTrimming = TextTrimming.CharacterEllipsis,
                            MaxWidth = 400
                        });
                    }

                    sp.Children.Add(textSp);
                    border.Child = sp;

                    var url = source.Url;
                    border.MouseLeftButtonUp += (s, e) =>
                    {
                        try
                        {
                            Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
                        }
                        catch { /* ignore */ }
                    };

                    SourcesPanel.Children.Add(border);
                }
            }
        }

        private void Copy_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                Clipboard.SetText(_result.Answer);
            }
            catch { /* ignore */ }
        }

        private void Close_Click(object sender, RoutedEventArgs e)
        {
            Close();
        }

        private void Window_KeyDown(object sender, KeyEventArgs e)
        {
            if (e.Key == Key.Escape)
            {
                Close();
                e.Handled = true;
            }
        }
    }
}
