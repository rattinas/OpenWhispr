"""Centralized settings management for WhisprFlow."""

import json
import os
from whisprflow.config import DATA_DIR

SETTINGS_PATH = os.path.join(DATA_DIR, "settings.json")
CUSTOM_MODES_PATH = os.path.join(DATA_DIR, "custom_modes.json")

_cache: dict | None = None


def _load() -> dict:
    global _cache
    if _cache is not None:
        return _cache
    if not os.path.exists(SETTINGS_PATH):
        _cache = {}
        return _cache
    try:
        with open(SETTINGS_PATH) as f:
            _cache = json.load(f)
    except (json.JSONDecodeError, IOError):
        _cache = {}
    return _cache


def _save(data: dict):
    global _cache
    _cache = data
    with open(SETTINGS_PATH, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)


def get(key: str, default=None):
    return _load().get(key, default)


def set(key: str, value):
    data = _load()
    data[key] = value
    _save(data)


def get_all() -> dict:
    return dict(_load())


# --- Convenience accessors ---

def get_anthropic_key() -> str | None:
    return get("anthropic_api_key")

def set_anthropic_key(key: str):
    set("anthropic_api_key", key)

def get_groq_key() -> str | None:
    return get("groq_api_key")

def set_groq_key(key: str):
    set("groq_api_key", key)

def get_polish_provider() -> str:
    return get("polish_provider", "ollama")

def set_polish_provider(provider: str):
    set("polish_provider", provider)

def get_stt_provider() -> str:
    return get("stt_provider", "local")

def set_stt_provider(provider: str):
    set("stt_provider", provider)

def get_hotkey() -> str:
    return get("hotkey", "ctrl")

def set_hotkey(key: str):
    set("hotkey", key)

def get_language() -> str | None:
    return get("language", "de")

def set_language(lang: str | None):
    set("language", lang)

def get_license_key() -> str | None:
    return get("license_key")

def set_license_key(key: str):
    set("license_key", key)

def get_trial_uses() -> int:
    return get("trial_uses", 0)

def increment_trial_uses():
    set("trial_uses", get_trial_uses() + 1)

def is_onboarded() -> bool:
    return get("onboarded", False)

def set_onboarded():
    set("onboarded", True)


# --- Custom Modes ---

def load_custom_modes() -> dict:
    if not os.path.exists(CUSTOM_MODES_PATH):
        return {}
    try:
        with open(CUSTOM_MODES_PATH) as f:
            return json.load(f)
    except (json.JSONDecodeError, IOError):
        return {}


def save_custom_modes(modes: dict):
    with open(CUSTOM_MODES_PATH, "w") as f:
        json.dump(modes, f, indent=2, ensure_ascii=False)


def add_custom_mode(key: str, label: str, prompt: str):
    modes = load_custom_modes()
    modes[key] = {"label": label, "prompt": prompt}
    save_custom_modes(modes)


def remove_custom_mode(key: str):
    modes = load_custom_modes()
    modes.pop(key, None)
    save_custom_modes(modes)


def update_mode_prompt(key: str, prompt: str):
    """Update prompt for a custom mode."""
    modes = load_custom_modes()
    if key in modes:
        modes[key]["prompt"] = prompt
        save_custom_modes(modes)
