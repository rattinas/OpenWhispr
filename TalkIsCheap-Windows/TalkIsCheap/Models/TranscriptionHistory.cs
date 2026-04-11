using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Newtonsoft.Json;

namespace TalkIsCheap.Models
{
    public class TranscriptionEntry
    {
        [JsonProperty("id")]
        public string Id { get; set; } = Guid.NewGuid().ToString();

        [JsonProperty("rawText")]
        public string RawText { get; set; } = "";

        [JsonProperty("polishedText")]
        public string PolishedText { get; set; } = "";

        [JsonProperty("mode")]
        public string Mode { get; set; } = "";

        [JsonProperty("duration")]
        public double Duration { get; set; }

        [JsonProperty("timestamp")]
        public DateTime Timestamp { get; set; } = DateTime.UtcNow;

        [JsonIgnore]
        public int WordCount => PolishedText.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length;
    }

    public class TranscriptionHistory
    {
        private static TranscriptionHistory? _instance;
        private static readonly object _lock = new();
        private static readonly string HistoryPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "TalkIsCheap", "history.json");

        public static TranscriptionHistory Shared
        {
            get
            {
                if (_instance == null)
                {
                    lock (_lock)
                    {
                        _instance ??= new TranscriptionHistory();
                    }
                }
                return _instance;
            }
        }

        public List<TranscriptionEntry> Entries { get; private set; } = new();

        public int TotalCount => Entries.Count;

        public int TotalWordCount => Entries.Sum(e => e.WordCount);

        public int TodayWordCount => Entries
            .Where(e => e.Timestamp.Date == DateTime.UtcNow.Date)
            .Sum(e => e.WordCount);

        private TranscriptionHistory()
        {
            Load();
        }

        public void Add(string raw, string polished, string mode, double duration)
        {
            Entries.Insert(0, new TranscriptionEntry
            {
                RawText = raw,
                PolishedText = polished,
                Mode = mode,
                Duration = duration,
                Timestamp = DateTime.UtcNow
            });

            // Keep max 500 entries
            if (Entries.Count > 500)
                Entries.RemoveRange(500, Entries.Count - 500);

            Save();
        }

        public void Clear()
        {
            Entries.Clear();
            Save();
        }

        private void Load()
        {
            try
            {
                if (File.Exists(HistoryPath))
                {
                    var json = File.ReadAllText(HistoryPath);
                    var entries = JsonConvert.DeserializeObject<List<TranscriptionEntry>>(json);
                    if (entries != null) Entries = entries;
                }
            }
            catch (Exception ex)
            {
                Services.Logger.Write($"Failed to load history: {ex.Message}");
            }
        }

        private void Save()
        {
            try
            {
                var dir = Path.GetDirectoryName(HistoryPath)!;
                Directory.CreateDirectory(dir);
                var json = JsonConvert.SerializeObject(Entries, Formatting.Indented);
                File.WriteAllText(HistoryPath, json);
            }
            catch (Exception ex)
            {
                Services.Logger.Write($"Failed to save history: {ex.Message}");
            }
        }
    }
}
