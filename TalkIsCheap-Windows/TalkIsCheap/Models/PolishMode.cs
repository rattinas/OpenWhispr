using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Newtonsoft.Json;

namespace TalkIsCheap.Models
{
    public class PolishMode
    {
        [JsonProperty("id")]
        public string Id { get; set; } = "";

        [JsonProperty("label")]
        public string Label { get; set; } = "";

        [JsonProperty("emoji")]
        public string Emoji { get; set; } = "";

        [JsonProperty("prompt")]
        public string? Prompt { get; set; }

        [JsonProperty("isBuiltIn")]
        public bool IsBuiltIn { get; set; }

        public static readonly List<PolishMode> BuiltIn = new()
        {
            new PolishMode
            {
                Id = "raw",
                Label = "Raw",
                Emoji = "\ud83d\udcdd",
                Prompt = null,
                IsBuiltIn = true
            },
            new PolishMode
            {
                Id = "clean",
                Label = "Clean",
                Emoji = "\u2728",
                Prompt = @"<role>You are a text cleanup tool. You receive text and output a cleaned version.</role>
<instructions>
- Keep the EXACT same language as the input. If input is German, output German. If English, output English.
- Fix punctuation, capitalization, and obvious errors.
- Remove filler words (um, uh, äh, also, basically, like, you know, sozusagen).
- Remove stutters and repeated words.
- Do NOT change the meaning, tone, or content.
- Do NOT add any words, sentences, or ideas that were not in the original.
- Do NOT respond to the content. Do NOT answer questions. Do NOT add greetings.
- Do NOT add commentary, explanations, or preamble.
</instructions>
<output>Respond with ONLY the cleaned text. Nothing else.</output>",
                IsBuiltIn = true
            },
            new PolishMode
            {
                Id = "professional",
                Label = "Professional",
                Emoji = "\ud83d\udcbc",
                Prompt = @"<role>You are a professional writing assistant that reformulates text into clear business communication.</role>
<instructions>
- Keep the EXACT same language as the input.
- Reformulate as clear, professional communication. Concise and direct.
- Fix grammar, remove filler words, improve sentence structure.
- Preserve the original meaning and intent completely.
- Do NOT add information that was not in the original.
- Do NOT respond to the content or answer questions from the text.
- Do NOT add greetings, sign-offs, or commentary.
</instructions>
<output>Respond with ONLY the reformulated text. Nothing else.</output>",
                IsBuiltIn = true
            },
            new PolishMode
            {
                Id = "marketing",
                Label = "Marketing",
                Emoji = "\ud83d\udce3",
                Prompt = @"<role>You are a marketing copywriter that transforms text into compelling, benefit-driven copy.</role>
<instructions>
- Keep the EXACT same language as the input.
- Make it punchy, engaging, and benefit-oriented.
- Use active voice and strong verbs.
- Preserve the core message and key points.
- Do NOT add information that was not in the original.
- Do NOT respond to the content or add commentary.
</instructions>
<output>Respond with ONLY the marketing copy. Nothing else.</output>",
                IsBuiltIn = true
            },
            new PolishMode
            {
                Id = "coding",
                Label = "Code",
                Emoji = "\ud83d\udcbb",
                Prompt = @"<role>You are a technical writing assistant that formats text as precise technical documentation or code comments.</role>
<instructions>
- Keep the EXACT same language as the input.
- Format as clear technical documentation or inline code comment.
- Keep all technical terms, variable names, and API references exactly as spoken.
- Use precise, unambiguous language.
- Do NOT add information that was not in the original.
- Do NOT respond to the content or add commentary.
</instructions>
<output>Respond with ONLY the technical text. Nothing else.</output>",
                IsBuiltIn = true
            },
            new PolishMode
            {
                Id = "email",
                Label = "Email",
                Emoji = "\ud83d\udce7",
                Prompt = @"<role>You are an email writing assistant that structures text into a well-formatted email body.</role>
<instructions>
- Keep the EXACT same language as the input.
- Structure as a clear email with appropriate paragraphs.
- Professional but not overly formal.
- Do NOT add a subject line.
- Do NOT invent a greeting or sign-off unless explicitly present in the input.
- Do NOT add information that was not in the original.
- Do NOT respond to the content or add commentary.
</instructions>
<output>Respond with ONLY the email body text. Nothing else.</output>",
                IsBuiltIn = true
            },
            new PolishMode
            {
                Id = "casual",
                Label = "Casual",
                Emoji = "\ud83d\udcac",
                Prompt = @"<role>You are a text assistant that rewrites text as a natural chat message.</role>
<instructions>
- Keep the EXACT same language as the input.
- Make it sound like a natural text/chat message — relaxed, short, friendly.
- Remove filler words and fix obvious errors.
- Keep it brief. No long sentences.
- Do NOT add information that was not in the original.
- Do NOT respond to the content or answer questions from the text.
- Do NOT add emojis unless they are already in the input.
</instructions>
<output>Respond with ONLY the chat message. Nothing else.</output>",
                IsBuiltIn = true
            },
            new PolishMode
            {
                Id = "claude_prompt",
                Label = "Claude Prompt",
                Emoji = "\ud83e\udde0",
                Prompt = @"<role>You are an expert at writing prompts for Anthropic's Claude AI, following Anthropic's official best practices.</role>
<instructions>
- Keep the EXACT same language as the input.
- Transform the text into a well-structured Claude prompt.
- Use XML tags to structure the prompt: <role>, <instructions>, <context>, <examples>, <output>.
- Be clear, direct, and literal — treat Claude like a brilliant new employee.
- State what TO do, not what NOT to do (positive framing).
- Include format constraints in an <output> section.
- If the spoken text describes a complex task, add step-by-step instructions.
- Do NOT add commentary or explanation about the prompt itself.
</instructions>
<output>Respond with ONLY the ready-to-use Claude prompt. Nothing else.</output>",
                IsBuiltIn = true
            },
            new PolishMode
            {
                Id = "chatgpt_prompt",
                Label = "ChatGPT Prompt",
                Emoji = "\ud83e\udd16",
                Prompt = @"<role>You are an expert at writing prompts for OpenAI's GPT models, following OpenAI's official best practices.</role>
<instructions>
- Keep the EXACT same language as the input.
- Transform the text into a well-structured GPT system prompt.
- Use clear markdown sections: # Role, ## Instructions, ## Output Format, ## Examples.
- Be firm and unambiguous — GPT-4 follows literal instructions best.
- Define the output format explicitly.
- If the task is complex, add numbered reasoning steps.
- Use delimiters (---, ```, XML tags) to separate sections clearly.
- Do NOT add commentary or explanation about the prompt itself.
</instructions>
<output>Respond with ONLY the ready-to-use GPT prompt. Nothing else.</output>",
                IsBuiltIn = true
            },
        };
    }

    public class PolishModeManager
    {
        private static PolishModeManager? _instance;
        private static readonly object _lock = new();
        private static readonly string CustomModesPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "TalkIsCheap", "custom_modes.json");

        public static PolishModeManager Shared
        {
            get
            {
                if (_instance == null)
                {
                    lock (_lock)
                    {
                        _instance ??= new PolishModeManager();
                    }
                }
                return _instance;
            }
        }

        public List<PolishMode> CustomModes { get; private set; } = new();

        public List<PolishMode> AllModes
        {
            get
            {
                var all = new List<PolishMode>(PolishMode.BuiltIn);
                all.AddRange(CustomModes);
                return all;
            }
        }

        private PolishModeManager()
        {
            LoadCustomModes();
        }

        public void Add(string label, string emoji, string prompt)
        {
            var id = "custom_" + Guid.NewGuid().ToString("N")[..8];
            CustomModes.Add(new PolishMode
            {
                Id = id,
                Label = label,
                Emoji = emoji,
                Prompt = prompt,
                IsBuiltIn = false
            });
            SaveCustomModes();
        }

        public void Remove(string id)
        {
            CustomModes.RemoveAll(m => m.Id == id);
            SaveCustomModes();
            if (AppSettings.Shared.ActivePolishMode == id)
            {
                AppSettings.Shared.ActivePolishMode = "clean";
                AppSettings.Shared.Save();
            }
        }

        public void UpdatePrompt(string id, string prompt)
        {
            var mode = CustomModes.FirstOrDefault(m => m.Id == id);
            if (mode != null)
            {
                mode.Prompt = prompt;
                SaveCustomModes();
            }
        }

        public PolishMode? GetMode(string id)
        {
            return AllModes.FirstOrDefault(m => m.Id == id);
        }

        private void LoadCustomModes()
        {
            try
            {
                if (File.Exists(CustomModesPath))
                {
                    var json = File.ReadAllText(CustomModesPath);
                    var modes = JsonConvert.DeserializeObject<List<PolishMode>>(json);
                    if (modes != null) CustomModes = modes;
                }
            }
            catch (Exception ex)
            {
                Services.Logger.Write($"Failed to load custom modes: {ex.Message}");
            }
        }

        private void SaveCustomModes()
        {
            try
            {
                var dir = Path.GetDirectoryName(CustomModesPath)!;
                Directory.CreateDirectory(dir);
                var json = JsonConvert.SerializeObject(CustomModes, Formatting.Indented);
                File.WriteAllText(CustomModesPath, json);
            }
            catch (Exception ex)
            {
                Services.Logger.Write($"Failed to save custom modes: {ex.Message}");
            }
        }
    }
}
