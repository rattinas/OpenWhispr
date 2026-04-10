"""Configuration and defaults for WhisprFlow."""

import os

APP_NAME = "WhisprFlow"
DATA_DIR = os.path.expanduser("~/.whisprflow")
DB_PATH = os.path.join(DATA_DIR, "whisprflow.db")
DICTIONARY_PATH = os.path.join(DATA_DIR, "dictionary.json")

# Audio
SAMPLE_RATE = 16000
CHANNELS = 1
DTYPE = "float32"
BLOCKSIZE = 1024

# Whisper
WHISPER_MODEL = "mlx-community/whisper-large-v3-turbo"
WHISPER_LANGUAGE = "de"  # Force German. Set to None for auto-detect.

# Ollama
OLLAMA_MODEL = "qwen2.5:3b"
OLLAMA_HOST = "http://localhost:11434"

# Hotkey (pynput Key enum name)
HOTKEY = "ctrl"

# Polishing system prompt
POLISH_SYSTEM_PROMPT = """Du bist ein Textbereinigungstool. Ändere NIEMALS den Inhalt oder die Bedeutung. Deine einzigen erlaubten Änderungen:
- Zeichensetzung und Gross-/Kleinschreibung korrigieren
- Füllwörter entfernen (ähm, also, halt, sozusagen, quasi)
- Stotterer und Wortwiederholungen entfernen
- Offensichtliche Transkriptionsfehler korrigieren

NICHT erlaubt: Sätze umformulieren, Wörter hinzufügen, Inhalt ändern, übersetzen.
Gib NUR den bereinigten Text aus. Keine Erklärungen."""

# App context tone profiles
APP_PROFILES = {
    "messaging": {
        "bundleIds": [
            "com.tinyspeck.slackmacgap", "net.whatsapp.WhatsApp",
            "com.hnc.Discord", "org.telegram.desktop",
            "com.microsoft.teams2", "com.microsoft.teams",
            "com.apple.MobileSMS", "com.apple.iChat",
            "com.signal.Signal", "ch.threema.threema",
        ],
        "tone": "The user is typing in a messaging app. Keep it casual and short. Use contractions. Don't over-formalize.",
    },
    "email": {
        "bundleIds": [
            "com.apple.mail", "com.microsoft.Outlook",
            "com.readdle.smartemail-macos", "com.superhuman.electron",
        ],
        "tone": "The user is composing an email. Use a professional, well-structured tone. Complete sentences, proper grammar.",
    },
    "coding": {
        "bundleIds": [
            "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
            "dev.zed.Zed", "com.apple.dt.Xcode",
            "com.googlecode.iterm2", "com.apple.Terminal",
            "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        ],
        "tone": "The user is in a code editor. Preserve all technical terms, variable names, and code-related language exactly. Keep it concise and technical.",
    },
}

os.makedirs(DATA_DIR, exist_ok=True)
