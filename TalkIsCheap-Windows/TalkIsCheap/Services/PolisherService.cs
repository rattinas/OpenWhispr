using System;
using System.Net.Http;
using System.Text;
using System.Threading.Tasks;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using TalkIsCheap.Models;

namespace TalkIsCheap.Services
{
    public class PolisherService
    {
        private static PolisherService? _instance;
        private static readonly object _lock = new();

        public static PolisherService Shared
        {
            get
            {
                if (_instance == null)
                {
                    lock (_lock)
                    {
                        _instance ??= new PolisherService();
                    }
                }
                return _instance;
            }
        }

        private readonly HttpClient _httpClient = new() { Timeout = TimeSpan.FromSeconds(30) };

        /// <summary>
        /// Polish text using Anthropic Claude API.
        /// </summary>
        public async Task<string> Polish(string text, PolishMode mode)
        {
            if (mode.Prompt == null) return text; // raw mode

            var apiKey = AppSettings.Shared.AnthropicApiKey;
            if (string.IsNullOrWhiteSpace(apiKey))
            {
                Logger.Write("Anthropic API key not set, returning raw text");
                return text;
            }

            try
            {
                var requestBody = new
                {
                    model = "claude-haiku-4-5-20251001",
                    max_tokens = 4096,
                    system = mode.Prompt,
                    messages = new[]
                    {
                        new { role = "user", content = text }
                    }
                };

                var json = JsonConvert.SerializeObject(requestBody);
                var request = new HttpRequestMessage(HttpMethod.Post, "https://api.anthropic.com/v1/messages");
                request.Headers.Add("x-api-key", apiKey);
                request.Headers.Add("anthropic-version", "2023-06-01");
                request.Content = new StringContent(json, Encoding.UTF8, "application/json");

                var response = await _httpClient.SendAsync(request);
                var responseText = await response.Content.ReadAsStringAsync();

                if (!response.IsSuccessStatusCode)
                {
                    Logger.Write($"Anthropic API error ({response.StatusCode}): {responseText}");
                    return text; // fallback to raw
                }

                var responseObj = JObject.Parse(responseText);
                var contentArray = responseObj["content"] as JArray;
                if (contentArray != null && contentArray.Count > 0)
                {
                    var firstBlock = contentArray[0];
                    if (firstBlock?["type"]?.ToString() == "text")
                    {
                        return firstBlock["text"]?.ToString()?.Trim() ?? text;
                    }
                }

                Logger.Write("Unexpected Anthropic response format");
                return text;
            }
            catch (Exception ex)
            {
                Logger.Write($"Polish error: {ex.Message}");
                return text; // fallback to raw
            }
        }
    }
}
