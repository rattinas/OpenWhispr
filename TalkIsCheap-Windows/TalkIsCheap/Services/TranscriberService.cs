using System;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Threading.Tasks;
using TalkIsCheap.Models;

namespace TalkIsCheap.Services
{
    public class TranscriberService
    {
        private static TranscriberService? _instance;
        private static readonly object _lock = new();

        public static TranscriberService Shared
        {
            get
            {
                if (_instance == null)
                {
                    lock (_lock)
                    {
                        _instance ??= new TranscriberService();
                    }
                }
                return _instance;
            }
        }

        private readonly HttpClient _httpClient = new() { Timeout = TimeSpan.FromSeconds(60) };

        // 16 kHz 16-bit mono = 32000 bytes/s; 0.5 s = 16000 PCM bytes + 44-byte WAV header
        private const int MinAudioBytes = 44 + 16000;

        /// <summary>
        /// Transcribe WAV audio data using configured provider (Groq Cloud or Local Whisper).
        /// </summary>
        public async Task<string> Transcribe(byte[] wavData, string? language)
        {
            if (wavData.Length < MinAudioBytes)
                throw new InvalidOperationException("Recording too short — hold the key for at least half a second.");

            if (AppSettings.Shared.SttProvider == "local")
            {
                return await WhisperLocalService.Shared.Transcribe(wavData, language);
            }

            var apiKey = AppSettings.Shared.GroqApiKey;
            if (string.IsNullOrWhiteSpace(apiKey))
                throw new InvalidOperationException("Groq API key not set. Open Settings to configure.");

            var boundary = Guid.NewGuid().ToString("N");
            var content = new MultipartFormDataContent(boundary);

            var fileContent = new ByteArrayContent(wavData);
            fileContent.Headers.ContentType = new MediaTypeHeaderValue("audio/wav");
            content.Add(fileContent, "file", "recording.wav");
            content.Add(new StringContent("whisper-large-v3"), "model");
            content.Add(new StringContent("text"), "response_format");

            if (!string.IsNullOrEmpty(language))
            {
                content.Add(new StringContent(language), "language");
            }

            var request = new HttpRequestMessage(HttpMethod.Post,
                "https://api.groq.com/openai/v1/audio/transcriptions");
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
            request.Content = content;

            var response = await _httpClient.SendAsync(request);
            var responseText = await response.Content.ReadAsStringAsync();

            if (!response.IsSuccessStatusCode)
            {
                Logger.Write($"Groq API error ({response.StatusCode}): {responseText}");
                throw new HttpRequestException($"Groq API error: {response.StatusCode}");
            }

            return responseText.Trim();
        }
    }
}
