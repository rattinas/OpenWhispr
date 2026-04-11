using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Threading.Tasks;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using TalkIsCheap.Models;

namespace TalkIsCheap.Services
{
    public class SearchResult
    {
        public string Query { get; set; } = "";
        public string Answer { get; set; } = "";
        public List<SearchSource> Sources { get; set; } = new();
    }

    public class SearchSource
    {
        public string Title { get; set; } = "";
        public string Url { get; set; } = "";
    }

    public class SearchService
    {
        private static SearchService? _instance;
        private static readonly object _lock = new();

        public static SearchService Shared
        {
            get
            {
                if (_instance == null)
                {
                    lock (_lock)
                    {
                        _instance ??= new SearchService();
                    }
                }
                return _instance;
            }
        }

        private readonly HttpClient _httpClient;

        private SearchService()
        {
            var handler = new HttpClientHandler
            {
                AutomaticDecompression = System.Net.DecompressionMethods.GZip | System.Net.DecompressionMethods.Deflate
            };
            _httpClient = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(30) };
        }

        /// <summary>
        /// Perform a voice search: Brave Search API + Claude summarization.
        /// </summary>
        public async Task<SearchResult> Search(string query)
        {
            var settings = AppSettings.Shared;
            var braveApiKey = settings.BraveApiKey;
            var anthropicApiKey = settings.AnthropicApiKey;

            if (string.IsNullOrWhiteSpace(braveApiKey))
                throw new InvalidOperationException("Brave Search API key not set. Open Settings to configure.");

            if (string.IsNullOrWhiteSpace(anthropicApiKey))
                throw new InvalidOperationException("Anthropic API key not set. Open Settings to configure.");

            // Step 1: Brave Search
            var searchResults = await BraveSearch(query, braveApiKey);

            // Step 2: Claude summarization
            var answer = await Summarize(query, searchResults, anthropicApiKey, settings.SearchModel);

            var sources = searchResults.Select(r => new SearchSource
            {
                Title = r.Title,
                Url = r.Url
            }).ToList();

            return new SearchResult
            {
                Query = query,
                Answer = answer,
                Sources = sources
            };
        }

        private async Task<List<BraveResult>> BraveSearch(string query, string apiKey)
        {
            var encodedQuery = Uri.EscapeDataString(query);
            var url = $"https://api.search.brave.com/res/v1/web/search?q={encodedQuery}&count=8";

            var request = new HttpRequestMessage(HttpMethod.Get, url);
            request.Headers.Add("Accept", "application/json");
            request.Headers.Add("Accept-Encoding", "gzip");
            request.Headers.Add("X-Subscription-Token", apiKey);

            var response = await _httpClient.SendAsync(request);
            var responseText = await response.Content.ReadAsStringAsync();

            if (!response.IsSuccessStatusCode)
            {
                Logger.Write($"Brave Search error ({response.StatusCode}): {responseText}");
                throw new HttpRequestException($"Brave Search error: {response.StatusCode}");
            }

            var json = JObject.Parse(responseText);
            var webResults = json["web"]?["results"] as JArray;
            if (webResults == null) return new List<BraveResult>();

            return webResults.Select(r => new BraveResult
            {
                Title = r["title"]?.ToString() ?? "",
                Url = r["url"]?.ToString() ?? "",
                Description = r["description"]?.ToString() ?? ""
            }).Take(8).ToList();
        }

        private async Task<string> Summarize(string query, List<BraveResult> results, string apiKey, string model)
        {
            var context = string.Join("\n\n", results.Select((r, i) =>
                $"[{i + 1}] {r.Title}\n{r.Url}\n{r.Description}"));

            var systemPrompt = @"You are a search assistant. Answer the user's question based on the search results provided.
Be concise but thorough. Use markdown formatting. Cite sources using [1], [2], etc.
Keep the same language as the user's question.
If the search results don't contain enough information, say so.";

            var requestBody = new
            {
                model = model,
                max_tokens = 2048,
                system = systemPrompt,
                messages = new[]
                {
                    new
                    {
                        role = "user",
                        content = $"Question: {query}\n\nSearch Results:\n{context}"
                    }
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
                Logger.Write($"Claude summarize error ({response.StatusCode}): {responseText}");
                throw new HttpRequestException($"Claude API error: {response.StatusCode}");
            }

            var responseObj = JObject.Parse(responseText);
            var contentArray = responseObj["content"] as JArray;
            if (contentArray != null && contentArray.Count > 0)
            {
                var firstBlock = contentArray[0];
                if (firstBlock?["type"]?.ToString() == "text")
                {
                    return firstBlock["text"]?.ToString()?.Trim() ?? "No answer generated.";
                }
            }

            return "Could not parse response.";
        }

        private class BraveResult
        {
            public string Title { get; set; } = "";
            public string Url { get; set; } = "";
            public string Description { get; set; } = "";
        }
    }
}
