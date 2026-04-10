"""Custom dictionary for improved transcription accuracy."""

import json
import os
from whisprflow.config import DICTIONARY_PATH


def load_dictionary() -> list[str]:
    if not os.path.exists(DICTIONARY_PATH):
        return []
    try:
        with open(DICTIONARY_PATH) as f:
            return json.load(f)
    except (json.JSONDecodeError, IOError):
        return []


def save_dictionary(words: list[str]):
    with open(DICTIONARY_PATH, "w") as f:
        json.dump(sorted(set(words)), f, ensure_ascii=False, indent=2)


def add_word(word: str):
    words = load_dictionary()
    word = word.strip()
    if word and word not in words:
        words.append(word)
        save_dictionary(words)


def remove_word(word: str):
    words = load_dictionary()
    words = [w for w in words if w != word.strip()]
    save_dictionary(words)


def get_whisper_prompt() -> str | None:
    """Return dictionary words as a Whisper prompt hint, or None."""
    words = load_dictionary()
    if not words:
        return None
    return ", ".join(words)
