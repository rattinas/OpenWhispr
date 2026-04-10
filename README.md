# WhisprFlow

Local-first voice-to-text dictation for macOS. Like Wispr Flow, but free and private.

## Features

- **Push-to-talk**: Hold CTRL to record, release to paste
- **Menu bar app**: Lives in your menu bar, no dock icon
- **Multiple polish modes**: Raw, Clean, Professional, Marketing, Email, Code Comment, Casual
- **Dual engine**: Groq (cloud, fast) or local Whisper (offline)
- **AI polishing**: Anthropic Claude (cloud) or Ollama (local)
- **App-aware**: Detects active app and adjusts tone (Slack = casual, Mail = professional)
- **Stats**: Track words dictated, time saved, top apps
- **Custom dictionary**: Add names and technical terms for better recognition
- **Offline mode**: Switch to local Whisper + Ollama when you have no internet

## Install

### Download

Grab the latest DMG from [Releases](../../releases), open it, drag WhisprFlow to Applications.

### From source

```bash
git clone https://github.com/anthropics/whisprflow.git
cd whisprflow
python3.11 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
python run.py
```

### Requirements

- macOS 13+, Apple Silicon
- [Ollama](https://ollama.com) (for local polishing) — `brew install ollama`
- Groq API key (free at [console.groq.com](https://console.groq.com)) for cloud STT
- Anthropic API key (at [console.anthropic.com](https://console.anthropic.com)) for cloud polishing

## Setup

1. Launch WhisprFlow — it appears in your menu bar as 🎙
2. Grant **Accessibility** permission (System Settings > Privacy > Accessibility)
3. Grant **Microphone** permission when prompted
4. Click 🔑 in the menu to add your API keys
5. Select your microphone under 🎤
6. Hold CTRL, speak, release — text appears at your cursor

## Polish Modes

| Mode | Use case |
|------|----------|
| Raw | Exact transcription, no changes |
| Clean | Fix punctuation, remove filler words |
| Professional | Clear, direct business communication |
| Marketing | Punchy, benefit-driven copy |
| Code Comment | Technical documentation style |
| Email | Structured email format |
| Casual | Chat message style |

## Architecture

```
[CTRL hold] → [Microphone] → [Groq/Whisper STT] → Raw text
                                → [Claude/Ollama LLM] → Polished text
                                      → [Clipboard + Auto-paste]
```

## Build

```bash
source venv/bin/activate
pip install pyinstaller
pyinstaller WhisprFlow.spec --noconfirm
# App at dist/WhisprFlow.app
# DMG:
hdiutil create -volname WhisprFlow -srcfolder dist/WhisprFlow.app -ov -format UDZO dist/WhisprFlow.dmg
```

## License

MIT
