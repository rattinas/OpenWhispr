"""Configuration and defaults for WhisprFlow."""

import os

VERSION = "2.0.0"
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

# Ollama
OLLAMA_MODEL = "qwen2.5:3b"

# Languages
LANGUAGES = {
    "auto": "Auto-Detect",
    "de": "Deutsch",
    "en": "English",
    "fr": "Français",
    "es": "Español",
    "it": "Italiano",
    "pt": "Português",
    "nl": "Nederlands",
    "pl": "Polski",
    "tr": "Türkçe",
    "ja": "日本語",
    "zh": "中文",
}

# Hotkey options
HOTKEYS = {
    "ctrl": "Control (hold)",
    "f5": "F5 (toggle)",
    "f6": "F6 (toggle)",
    "f8": "F8 (toggle)",
}

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
        "tone": "Context: messaging app. Keep it casual and short.",
    },
    "email": {
        "bundleIds": [
            "com.apple.mail", "com.microsoft.Outlook",
            "com.readdle.smartemail-macos", "com.superhuman.electron",
        ],
        "tone": "Context: email. Professional, well-structured tone.",
    },
    "coding": {
        "bundleIds": [
            "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
            "dev.zed.Zed", "com.apple.dt.Xcode",
            "com.googlecode.iterm2", "com.apple.Terminal",
            "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        ],
        "tone": "Context: code editor. Keep technical terms exact. Be concise.",
    },
}

os.makedirs(DATA_DIR, exist_ok=True)
