using System;
using System.IO;

namespace TalkIsCheap.Services
{
    public static class Logger
    {
        private static readonly string LogDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "TalkIsCheap");
        public static readonly string LogPath = Path.Combine(LogDir, "debug.log");
        private static readonly object _lock = new();

        public static void Write(string message)
        {
            try
            {
                lock (_lock)
                {
                    Directory.CreateDirectory(LogDir);
                    var line = $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff}] {message}\n";
                    File.AppendAllText(LogPath, line);

                    // Truncate if > 5MB
                    var info = new FileInfo(LogPath);
                    if (info.Exists && info.Length > 5 * 1024 * 1024)
                    {
                        var lines = File.ReadAllLines(LogPath);
                        var keep = lines[^500..];
                        File.WriteAllLines(LogPath, keep);
                    }
                }
            }
            catch
            {
                // Silently fail — logging should never crash the app
            }
        }
    }
}
