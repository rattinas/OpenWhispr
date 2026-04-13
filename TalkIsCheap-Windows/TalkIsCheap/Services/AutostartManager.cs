using System;
using Microsoft.Win32;

namespace TalkIsCheap.Services
{
    public static class AutostartManager
    {
        private const string AppName = "TalkIsCheap";
        private const string RunKey = @"SOFTWARE\Microsoft\Windows\CurrentVersion\Run";

        public static bool IsEnabled
        {
            get
            {
                try
                {
                    using var key = Registry.CurrentUser.OpenSubKey(RunKey, false);
                    return key?.GetValue(AppName) != null;
                }
                catch
                {
                    return false;
                }
            }
        }

        public static void Enable()
        {
            try
            {
                var exePath = Environment.ProcessPath ?? "";
                if (string.IsNullOrEmpty(exePath)) return;

                using var key = Registry.CurrentUser.OpenSubKey(RunKey, true);
                key?.SetValue(AppName, $"\"{exePath}\" --background");
                Logger.Write($"Autostart enabled: {exePath}");
            }
            catch (Exception ex)
            {
                Logger.Write($"Autostart enable failed: {ex.Message}");
            }
        }

        public static void Disable()
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(RunKey, true);
                key?.DeleteValue(AppName, false);
                Logger.Write("Autostart disabled");
            }
            catch (Exception ex)
            {
                Logger.Write($"Autostart disable failed: {ex.Message}");
            }
        }

        public static void SetEnabled(bool enabled)
        {
            if (enabled) Enable();
            else Disable();
        }
    }
}
