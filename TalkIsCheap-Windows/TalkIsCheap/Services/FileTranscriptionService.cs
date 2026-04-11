using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Threading.Tasks;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using TalkIsCheap.Models;

namespace TalkIsCheap.Services
{
    public class FileTranscriptionService
    {
        private static FileTranscriptionService? _instance;
        private static readonly object _lock = new();

        public static FileTranscriptionService Shared
        {
            get
            {
                if (_instance == null)
                {
                    lock (_lock)
                    {
                        _instance ??= new FileTranscriptionService();
                    }
                }
                return _instance;
            }
        }

        private readonly HttpClient _httpClient = new() { Timeout = TimeSpan.FromSeconds(120) };
        private const int MaxChunkSize = 24 * 1024 * 1024;
        private static readonly string TmpDir = Path.Combine(Path.GetTempPath(), "TalkIsCheap");

        private static readonly string[] AudioExtensions = { "mp3", "wav", "m4a", "ogg", "flac", "wma", "aac" };
        private static readonly string[] VideoExtensions = { "mp4", "mov", "avi", "mkv", "webm", "flv", "m4v", "wmv" };
        private static readonly string[] DocumentExtensions = { "pdf" };

        /// <summary>
        /// Transcribe a file (audio, video, or PDF).
        /// </summary>
        public async Task<string> Transcribe(string filePath)
        {
            Logger.Write($"FileTranscription: {filePath}");
            var ext = Path.GetExtension(filePath).TrimStart('.').ToLowerInvariant();

            if (DocumentExtensions.Contains(ext))
            {
                return ExtractText(filePath, ext);
            }

            // Audio/video: compress and transcribe
            Directory.CreateDirectory(TmpDir);
            var compressedPath = await ExtractAndCompress(filePath);
            var data = await File.ReadAllBytesAsync(compressedPath);
            Logger.Write($"Compressed: {data.Length / 1024}KB");

            var apiKey = AppSettings.Shared.GroqApiKey;
            if (string.IsNullOrWhiteSpace(apiKey))
                throw new InvalidOperationException("Groq API key not set. Open Settings to configure.");

            string transcript;
            if (data.Length <= MaxChunkSize)
            {
                transcript = await TranscribeGroq(data, "audio.mp3", apiKey);
            }
            else
            {
                transcript = await TranscribeGroqChunked(compressedPath, apiKey);
            }

            Cleanup();
            return transcript;
        }

        /// <summary>
        /// Summarize text using Claude API.
        /// </summary>
        public async Task<string> Summarize(string transcript)
        {
            var apiKey = AppSettings.Shared.AnthropicApiKey;
            if (string.IsNullOrWhiteSpace(apiKey)) return "";

            var model = AppSettings.Shared.SearchModel;
            var requestBody = new
            {
                model = model,
                max_tokens = 2048,
                system = "Summarize concisely. Same language. Key points, decisions, action items.",
                messages = new[] { new { role = "user", content = transcript } }
            };

            var json = JsonConvert.SerializeObject(requestBody);
            var request = new HttpRequestMessage(HttpMethod.Post, "https://api.anthropic.com/v1/messages");
            request.Headers.Add("x-api-key", apiKey);
            request.Headers.Add("anthropic-version", "2023-06-01");
            request.Content = new StringContent(json, Encoding.UTF8, "application/json");

            var response = await _httpClient.SendAsync(request);
            var responseText = await response.Content.ReadAsStringAsync();

            if (!response.IsSuccessStatusCode) return "";

            var responseObj = JObject.Parse(responseText);
            var contentArray = responseObj["content"] as JArray;
            if (contentArray?.Count > 0)
            {
                var first = contentArray[0];
                if (first?["type"]?.ToString() == "text")
                    return first["text"]?.ToString()?.Trim() ?? "";
            }
            return "";
        }

        // MARK: - Text Extraction

        private string ExtractText(string filePath, string ext)
        {
            return ext switch
            {
                "pdf" => ExtractPdfText(filePath),
                _ => throw new InvalidOperationException("Unsupported format")
            };
        }

        private string ExtractPdfText(string filePath)
        {
            // Basic PDF text extraction — reads text content between stream markers
            // For production use, consider a library like iTextSharp or PdfPig
            try
            {
                var bytes = File.ReadAllBytes(filePath);
                var text = new StringBuilder();

                // Simple extraction of text content from PDF
                var content = Encoding.Latin1.GetString(bytes);
                var index = 0;
                while ((index = content.IndexOf("BT", index, StringComparison.Ordinal)) >= 0)
                {
                    var end = content.IndexOf("ET", index, StringComparison.Ordinal);
                    if (end < 0) break;

                    var block = content[index..end];
                    // Extract text from Tj and TJ operators
                    var tjIndex = 0;
                    while ((tjIndex = block.IndexOf('(', tjIndex)) >= 0)
                    {
                        var closeIndex = block.IndexOf(')', tjIndex);
                        if (closeIndex < 0) break;
                        text.Append(block[(tjIndex + 1)..closeIndex]);
                        tjIndex = closeIndex + 1;
                    }
                    text.Append(' ');
                    index = end + 2;
                }

                var result = text.ToString().Trim();
                Logger.Write($"PDF extracted: {result.Length} chars");

                if (string.IsNullOrWhiteSpace(result))
                    throw new InvalidOperationException("PDF contains no extractable text");

                return result;
            }
            catch (InvalidOperationException)
            {
                throw;
            }
            catch (Exception ex)
            {
                throw new InvalidOperationException($"Failed to extract PDF text: {ex.Message}");
            }
        }

        // MARK: - FFmpeg

        private async Task<string> ExtractAndCompress(string filePath)
        {
            var ext = Path.GetExtension(filePath).TrimStart('.').ToLowerInvariant();
            var isVideo = VideoExtensions.Contains(ext);
            var compressedPath = Path.Combine(TmpDir, "compressed.mp3");

            if (File.Exists(compressedPath))
                File.Delete(compressedPath);

            // Try to find ffmpeg
            var ffmpegPath = FindFfmpeg();
            if (ffmpegPath == null)
                throw new InvalidOperationException("ffmpeg not found. Install ffmpeg and add it to PATH.");

            var args = $"-i \"{filePath}\"";
            if (isVideo) args += " -vn";
            args += $" -ac 1 -ar 16000 -b:a 48k -y \"{compressedPath}\"";

            var process = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = ffmpegPath,
                    Arguments = args,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true
                }
            };

            process.Start();
            await process.WaitForExitAsync();

            if (process.ExitCode != 0)
                throw new InvalidOperationException("ffmpeg failed to process file");

            return compressedPath;
        }

        private string? FindFfmpeg()
        {
            // Check common locations
            var paths = new[]
            {
                "ffmpeg", // on PATH
                @"C:\ffmpeg\bin\ffmpeg.exe",
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "ffmpeg", "bin", "ffmpeg.exe"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "WinGet", "Packages", "ffmpeg.exe")
            };

            foreach (var path in paths)
            {
                try
                {
                    var process = new Process
                    {
                        StartInfo = new ProcessStartInfo
                        {
                            FileName = path,
                            Arguments = "-version",
                            UseShellExecute = false,
                            CreateNoWindow = true,
                            RedirectStandardOutput = true,
                            RedirectStandardError = true
                        }
                    };
                    process.Start();
                    process.WaitForExit(3000);
                    if (process.ExitCode == 0) return path;
                }
                catch { /* try next */ }
            }

            return null;
        }

        // MARK: - Groq Transcription

        private async Task<string> TranscribeGroq(byte[] data, string fileName, string apiKey)
        {
            var content = new MultipartFormDataContent();
            var fileContent = new ByteArrayContent(data);
            fileContent.Headers.ContentType = new MediaTypeHeaderValue("audio/mpeg");
            content.Add(fileContent, "file", fileName);
            content.Add(new StringContent("whisper-large-v3"), "model");
            content.Add(new StringContent("text"), "response_format");

            var request = new HttpRequestMessage(HttpMethod.Post,
                "https://api.groq.com/openai/v1/audio/transcriptions");
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
            request.Content = content;

            var response = await _httpClient.SendAsync(request);
            var responseText = await response.Content.ReadAsStringAsync();

            if (!response.IsSuccessStatusCode)
                throw new HttpRequestException($"Groq API error: {response.StatusCode}");

            return responseText.Trim();
        }

        private async Task<string> TranscribeGroqChunked(string inputPath, string apiKey)
        {
            // Split into 5-minute chunks with ffmpeg
            var ffmpegPath = FindFfmpeg() ?? throw new InvalidOperationException("ffmpeg not found");

            // Get duration
            var probe = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = ffmpegPath.Replace("ffmpeg", "ffprobe"),
                    Arguments = $"-v quiet -show_entries format=duration -of csv=p=0 \"{inputPath}\"",
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true
                }
            };
            probe.Start();
            var durationStr = await probe.StandardOutput.ReadToEndAsync();
            await probe.WaitForExitAsync();

            var totalDuration = double.TryParse(durationStr.Trim(), out var d) ? d : 0;
            var chunkDuration = 300; // 5 minutes
            var chunkCount = (int)Math.Ceiling(totalDuration / chunkDuration);

            var fullTranscript = new StringBuilder();
            for (int i = 0; i < chunkCount; i++)
            {
                var chunkPath = Path.Combine(TmpDir, $"chunk_{i}.mp3");
                var split = new Process
                {
                    StartInfo = new ProcessStartInfo
                    {
                        FileName = ffmpegPath,
                        Arguments = $"-i \"{inputPath}\" -ss {i * chunkDuration} -t {chunkDuration} -c copy -y \"{chunkPath}\"",
                        UseShellExecute = false,
                        CreateNoWindow = true,
                        RedirectStandardOutput = true,
                        RedirectStandardError = true
                    }
                };
                split.Start();
                await split.WaitForExitAsync();

                if (File.Exists(chunkPath))
                {
                    var data = await File.ReadAllBytesAsync(chunkPath);
                    var text = await TranscribeGroq(data, $"chunk_{i}.mp3", apiKey);
                    if (fullTranscript.Length > 0) fullTranscript.Append(' ');
                    fullTranscript.Append(text);
                }
            }

            return fullTranscript.ToString();
        }

        private void Cleanup()
        {
            try
            {
                if (Directory.Exists(TmpDir))
                    Directory.Delete(TmpDir, true);
            }
            catch { /* ignore */ }
        }
    }
}
