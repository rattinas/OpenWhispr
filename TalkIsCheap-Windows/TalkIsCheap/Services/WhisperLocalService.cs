using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Net.Http;
using System.Threading.Tasks;
using TalkIsCheap.Models;

namespace TalkIsCheap.Services
{
    public class WhisperLocalService
    {
        private static WhisperLocalService? _instance;
        private static readonly object _lock = new();

        public static WhisperLocalService Shared
        {
            get
            {
                if (_instance == null)
                {
                    lock (_lock)
                    {
                        _instance ??= new WhisperLocalService();
                    }
                }
                return _instance;
            }
        }

        private static readonly string WhisperDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "TalkIsCheap", "whisper");

        private static string BinaryPath => Path.Combine(WhisperDir, "main.exe");

        private static string ModelPath(string model) =>
            Path.Combine(WhisperDir, $"ggml-{model}.bin");

        // whisper.cpp release binary (Windows x64)
        private const string BinaryUrl =
            "https://github.com/ggerganov/whisper.cpp/releases/download/v1.7.3/whisper-bin-x64.zip";

        // Model URLs from HuggingFace
        private static string ModelUrl(string model) =>
            $"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-{model}.bin";

        public bool IsReady
        {
            get
            {
                var model = AppSettings.Shared.WhisperModel;
                return File.Exists(BinaryPath) && File.Exists(ModelPath(model));
            }
        }

        public bool BinaryExists => File.Exists(BinaryPath);
        public bool ModelExists => File.Exists(ModelPath(AppSettings.Shared.WhisperModel));

        /// <summary>
        /// Download whisper.cpp binary and model. Reports progress via callback (0-100).
        /// </summary>
        public async Task Download(string model, Action<int, string>? onProgress = null)
        {
            Directory.CreateDirectory(WhisperDir);

            var handler = new HttpClientHandler
            {
                AutomaticDecompression = System.Net.DecompressionMethods.GZip | System.Net.DecompressionMethods.Deflate
            };
            using var http = new HttpClient(handler) { Timeout = TimeSpan.FromMinutes(30) };

            // Step 1: Download binary (zip) if needed
            if (!File.Exists(BinaryPath))
            {
                onProgress?.Invoke(0, "Downloading whisper.cpp binary...");
                Logger.Write($"Downloading whisper.cpp from {BinaryUrl}");

                var zipPath = Path.Combine(WhisperDir, "whisper-bin.zip");
                await DownloadFile(http, BinaryUrl, zipPath, (pct) =>
                    onProgress?.Invoke(pct / 4, $"Downloading binary... {pct}%"));

                // Extract main.exe from zip
                onProgress?.Invoke(25, "Extracting binary...");
                var extractDir = Path.Combine(WhisperDir, "extract");
                if (Directory.Exists(extractDir))
                    Directory.Delete(extractDir, true);

                ZipFile.ExtractToDirectory(zipPath, extractDir);

                // Find the whisper CLI binary in extracted files.
                // whisper.cpp < v1.6.2 ships "main.exe"; v1.6.2+ ships "whisper-cli.exe".
                var mainExe = FindFile(extractDir, "main.exe")
                    ?? FindFile(extractDir, "whisper-cli.exe")
                    ?? FindFile(extractDir, "whisper.exe");
                if (mainExe != null)
                {
                    File.Copy(mainExe, BinaryPath, true);
                    Logger.Write($"Extracted whisper binary to {BinaryPath}");
                }
                else
                {
                    // Copy all exe and dll files to whisper dir as fallback
                    foreach (var file in Directory.GetFiles(extractDir, "*.*", SearchOption.AllDirectories))
                    {
                        var ext = Path.GetExtension(file).ToLower();
                        if (ext is ".exe" or ".dll")
                        {
                            var destFile = Path.Combine(WhisperDir, Path.GetFileName(file));
                            File.Copy(file, destFile, true);
                        }
                    }
                    Logger.Write("Extracted all binaries to whisper dir");
                }

                // Cleanup
                try { Directory.Delete(extractDir, true); } catch { }
                try { File.Delete(zipPath); } catch { }
            }

            // Step 2: Download model if needed
            var modelPath = ModelPath(model);
            if (!File.Exists(modelPath))
            {
                var url = ModelUrl(model);
                onProgress?.Invoke(25, $"Downloading ggml-{model} model...");
                Logger.Write($"Downloading model from {url}");

                await DownloadFile(http, url, modelPath, (pct) =>
                    onProgress?.Invoke(25 + (pct * 3 / 4), $"Downloading model... {pct}%"));
            }

            onProgress?.Invoke(100, "Ready!");
            Logger.Write("Whisper local setup complete");
        }

        /// <summary>
        /// Transcribe WAV audio data using local whisper.cpp.
        /// </summary>
        public async Task<string> Transcribe(byte[] wavData, string? language)
        {
            var model = AppSettings.Shared.WhisperModel;

            if (!File.Exists(BinaryPath))
                throw new InvalidOperationException("whisper.cpp not found. Select Local Whisper in Settings to download.");

            if (!File.Exists(ModelPath(model)))
                throw new InvalidOperationException($"Whisper model ggml-{model} not found. Open Settings to download.");

            // Write WAV to temp file
            var tempWav = Path.Combine(Path.GetTempPath(), $"talkischeap_{Guid.NewGuid():N}.wav");
            await File.WriteAllBytesAsync(tempWav, wavData);

            try
            {
                // Build arguments
                var args = $"-m \"{ModelPath(model)}\" -f \"{tempWav}\" --no-timestamps -otxt";
                if (!string.IsNullOrEmpty(language))
                    args += $" -l {language}";

                Logger.Write($"Running: main.exe {args}");

                var psi = new ProcessStartInfo
                {
                    FileName = BinaryPath,
                    Arguments = args,
                    WorkingDirectory = WhisperDir,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true
                };

                using var process = new System.Diagnostics.Process();
                process.StartInfo = psi;
                process.Start();

                var stdout = await process.StandardOutput.ReadToEndAsync();
                var stderr = await process.StandardError.ReadToEndAsync();

                await process.WaitForExitAsync();

                if (!string.IsNullOrWhiteSpace(stderr))
                    Logger.Write($"whisper stderr: {stderr[..Math.Min(200, stderr.Length)]}");

                // whisper.cpp with -otxt creates a .txt file next to the input
                var txtFile = tempWav + ".txt";
                string result;
                if (File.Exists(txtFile))
                {
                    result = (await File.ReadAllTextAsync(txtFile)).Trim();
                    try { File.Delete(txtFile); } catch { }
                }
                else
                {
                    // Fallback: use stdout
                    result = stdout.Trim();
                }

                Logger.Write($"Local whisper result: {result[..Math.Min(80, result.Length)]}...");
                return result;
            }
            finally
            {
                try { File.Delete(tempWav); } catch { }
            }
        }

        private static async Task DownloadFile(HttpClient http, string url, string destPath, Action<int>? onProgress = null)
        {
            using var response = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead);
            response.EnsureSuccessStatusCode();

            var totalBytes = response.Content.Headers.ContentLength ?? -1;
            using var stream = await response.Content.ReadAsStreamAsync();
            using var fileStream = new FileStream(destPath, FileMode.Create, FileAccess.Write, FileShare.None, 8192);

            var buffer = new byte[8192];
            long totalRead = 0;
            int lastPct = -1;

            while (true)
            {
                var bytesRead = await stream.ReadAsync(buffer);
                if (bytesRead == 0) break;

                await fileStream.WriteAsync(buffer.AsMemory(0, bytesRead));
                totalRead += bytesRead;

                if (totalBytes > 0)
                {
                    var pct = (int)(totalRead * 100 / totalBytes);
                    if (pct != lastPct)
                    {
                        lastPct = pct;
                        onProgress?.Invoke(pct);
                    }
                }
            }
        }

        private static string? FindFile(string dir, string filename)
        {
            foreach (var file in Directory.GetFiles(dir, filename, SearchOption.AllDirectories))
                return file;
            return null;
        }
    }
}
