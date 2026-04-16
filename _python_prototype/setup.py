"""py2app setup for WhisprFlow."""

from setuptools import setup

APP = ["run.py"]
DATA_FILES = []

OPTIONS = {
    "argv_emulation": False,
    "iconfile": "assets/WhisprFlow.icns",
    "plist": {
        "CFBundleName": "WhisprFlow",
        "CFBundleDisplayName": "WhisprFlow",
        "CFBundleIdentifier": "com.whisprflow.app",
        "CFBundleVersion": "1.0.0",
        "CFBundleShortVersionString": "1.0.0",
        "LSMinimumSystemVersion": "13.0",
        "LSUIElement": True,  # Hide from Dock, menu bar only
        "NSMicrophoneUsageDescription": "WhisprFlow needs microphone access for voice dictation.",
        "NSAppleEventsUsageDescription": "WhisprFlow needs accessibility to paste text at your cursor.",
    },
    "packages": [
        "whisprflow",
        "mlx_whisper",
        "mlx",
        "sounddevice",
        "soundfile",
        "numpy",
        "pynput",
        "rumps",
        "ollama",
        "anthropic",
        "groq",
        "httpx",
        "httpcore",
        "anyio",
        "certifi",
        "tiktoken",
    ],
    "includes": [
        "AppKit",
        "Foundation",
        "Quartz",
    ],
    "resources": ["assets"],
    "strip": True,
    "optimize": 2,
}

setup(
    app=APP,
    data_files=DATA_FILES,
    options={"py2app": OPTIONS},
    setup_requires=["py2app"],
)
