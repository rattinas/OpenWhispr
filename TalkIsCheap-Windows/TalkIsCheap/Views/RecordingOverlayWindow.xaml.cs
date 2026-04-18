using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using System.Windows.Threading;
using TalkIsCheap.Models;

namespace TalkIsCheap.Views
{
    public partial class RecordingOverlayWindow : Window
    {
        private readonly DispatcherTimer _blinkTimer = new() { Interval = TimeSpan.FromMilliseconds(600) };
        private readonly DispatcherTimer _spokeTimer = new() { Interval = TimeSpan.FromMilliseconds(30) };
        private double _spokeAngle;
        private bool _dotVisible = true;

        private const double SizeStep = 0.15;
        private const double SizeMin = 0.5;
        private const double SizeMax = 2.5;

        public RecordingOverlayWindow()
        {
            InitializeComponent();
            BuildSpokes();
            ApplySize(AppSettings.Shared.CassetteSize);

            _blinkTimer.Tick += (s, e) =>
            {
                _dotVisible = !_dotVisible;
                RecDot.Opacity = _dotVisible ? 1.0 : 0.25;
            };

            _spokeTimer.Tick += (s, e) =>
            {
                _spokeAngle = (_spokeAngle + 8) % 360;
                RotateSpokes(SpoolLeftSpokes, _spokeAngle);
                RotateSpokes(SpoolRightSpokes, _spokeAngle);
            };

            PositionAtBottom();
        }

        private void BuildSpokes()
        {
            AddSpokes(SpoolLeftSpokes);
            AddSpokes(SpoolRightSpokes);
        }

        private static void AddSpokes(Canvas canvas)
        {
            for (int i = 0; i < 3; i++)
            {
                double angle = i * 120 * Math.PI / 180;
                double cx = 0, cy = 0, r = 5;
                var line = new Line
                {
                    X1 = cx - r * Math.Sin(angle),
                    Y1 = cy - r * Math.Cos(angle),
                    X2 = cx + r * Math.Sin(angle),
                    Y2 = cy + r * Math.Cos(angle),
                    Stroke = new SolidColorBrush(Color.FromArgb(180, 255, 255, 255)),
                    StrokeThickness = 1
                };
                canvas.Children.Add(line);
            }
        }

        private static void RotateSpokes(Canvas canvas, double angle)
        {
            canvas.RenderTransform = new RotateTransform(angle);
        }

        public void StartAnimation()
        {
            _blinkTimer.Start();
            _spokeTimer.Start();
        }

        public void StopAnimation()
        {
            _blinkTimer.Stop();
            _spokeTimer.Stop();
            RecDot.Opacity = 0.3;
        }

        private void PositionAtBottom()
        {
            var screen = SystemParameters.WorkArea;
            Left = screen.Left + (screen.Width - ActualWidth) / 2;
            Top = screen.Bottom - ActualHeight - 24;
        }

        protected override void OnContentRendered(EventArgs e)
        {
            base.OnContentRendered(e);
            PositionAtBottom();
        }

        private void CassetteCard_MouseDown(object sender, System.Windows.Input.MouseButtonEventArgs e)
        {
            if (e.LeftButton == System.Windows.Input.MouseButtonState.Pressed)
                DragMove();
        }

        private void BtnIncrease_Click(object sender, RoutedEventArgs e)
        {
            var newSize = Math.Min(AppSettings.Shared.CassetteSize + SizeStep, SizeMax);
            ApplySize(newSize);
            SaveSize(newSize);
        }

        private void BtnDecrease_Click(object sender, RoutedEventArgs e)
        {
            var newSize = Math.Max(AppSettings.Shared.CassetteSize - SizeStep, SizeMin);
            ApplySize(newSize);
            SaveSize(newSize);
        }

        private void ApplySize(double scale)
        {
            CassetteCanvas.LayoutTransform = new ScaleTransform(scale, scale);
            PositionAtBottom();
        }

        private static void SaveSize(double scale)
        {
            AppSettings.Shared.CassetteSize = scale;
            AppSettings.Shared.Save();
        }
    }
}
