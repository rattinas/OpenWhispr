"""Text polishing via Anthropic Claude or Ollama."""

import json
import os
from whisprflow.config import DATA_DIR

SETTINGS_PATH = os.path.join(DATA_DIR, "settings.json")

# --- Polishing Modes ---
# Each mode: short name, label for menu, system prompt
BASE_INSTRUCTION = "WICHTIG: Behalte die Sprache des Inputs bei. Wenn der Input auf Deutsch ist, antworte auf Deutsch. Wenn auf Englisch, antworte auf Englisch. Gib NUR den Ergebnistext aus — keine Erklärungen, keine Kommentare.\n\n"

MODES = {
    "raw": {
        "label": "Raw (no polish)",
        "prompt": None,
    },
    "clean": {
        "label": "Clean",
        "prompt": BASE_INSTRUCTION + "Korrigiere nur Zeichensetzung und Gross-/Kleinschreibung. Entferne Füllwörter und Stotterer. Ändere sonst nichts.",
    },
    "professional": {
        "label": "Professional",
        "prompt": BASE_INSTRUCTION + "Formuliere als klare, professionelle Kommunikation. Korrigiere Grammatik, entferne Füllwörter. Präzise und direkt. Behalte alle Fakten und die Bedeutung bei.",
    },
    "marketing": {
        "label": "Marketing",
        "prompt": BASE_INSTRUCTION + "Formuliere als überzeugende Marketing-Texte. Mach es knackig, nutzenorientiert und ansprechend. Entferne Füllwörter. Behalte die Kernaussage.",
    },
    "coding": {
        "label": "Code Comment",
        "prompt": BASE_INSTRUCTION + "Formuliere als präzisen technischen Kommentar oder Dokumentation. Technische Fachsprache. Keine Füllwörter. Behalte alle technischen Begriffe exakt bei.",
    },
    "email": {
        "label": "Email",
        "prompt": BASE_INSTRUCTION + "Formuliere als gut strukturierte E-Mail. Professioneller Ton, klare Absätze. Kurz und prägnant.",
    },
    "casual": {
        "label": "Casual",
        "prompt": BASE_INSTRUCTION + "Bereinige für eine Chat-Nachricht. Locker, kurz und natürlich. Entferne Füllwörter aber behalte den informellen Ton.",
    },
}

DEFAULT_MODE = "clean"


def _load_settings() -> dict:
    if not os.path.exists(SETTINGS_PATH):
        return {}
    try:
        with open(SETTINGS_PATH) as f:
            return json.load(f)
    except (json.JSONDecodeError, IOError):
        return {}


def _save_settings(settings: dict):
    with open(SETTINGS_PATH, "w") as f:
        json.dump(settings, f, indent=2)


def get_api_key() -> str | None:
    return _load_settings().get("anthropic_api_key")


def save_api_key(key: str):
    s = _load_settings()
    s["anthropic_api_key"] = key
    _save_settings(s)


def get_provider() -> str:
    """Return 'anthropic' or 'ollama'."""
    return _load_settings().get("polish_provider", "ollama")


def save_provider(provider: str):
    s = _load_settings()
    s["polish_provider"] = provider
    _save_settings(s)


class Polisher:
    def __init__(self):
        self._mode = DEFAULT_MODE
        self._ollama_warmed = False

    @property
    def mode(self) -> str:
        return self._mode

    @mode.setter
    def mode(self, value: str):
        if value in MODES:
            self._mode = value

    def warm_up(self):
        """Pre-load Ollama model if using local provider."""
        if get_provider() == "ollama" and not self._ollama_warmed:
            try:
                import ollama
                from whisprflow.config import OLLAMA_MODEL
                ollama.chat(model=OLLAMA_MODEL, messages=[{"role": "user", "content": "hi"}],
                            options={"num_predict": 1})
                self._ollama_warmed = True
            except Exception:
                pass

    def polish(self, raw_text: str, extra_context: str = "") -> str:
        if not raw_text.strip():
            return ""

        mode = MODES.get(self._mode, MODES[DEFAULT_MODE])
        if mode["prompt"] is None:
            return raw_text  # raw mode

        system = mode["prompt"]
        if extra_context:
            system += "\n" + extra_context

        provider = get_provider()
        api_key = get_api_key()

        if provider == "anthropic" and api_key:
            print(f"[WhisprFlow] Using Anthropic Claude")
            return self._polish_anthropic(raw_text, system, api_key)
        else:
            print(f"[WhisprFlow] Using Ollama (provider={provider}, has_key={bool(api_key)})")
            return self._polish_ollama(raw_text, system)

    def _polish_anthropic(self, text: str, system: str, api_key: str) -> str:
        try:
            import anthropic
            client = anthropic.Anthropic(api_key=api_key)
            response = client.messages.create(
                model="claude-haiku-4-5-20251001",
                max_tokens=1024,
                system=system,
                messages=[{"role": "user", "content": text}],
            )
            return response.content[0].text.strip()
        except Exception as e:
            print(f"[WhisprFlow] Anthropic error: {e}, falling back to Ollama")
            return self._polish_ollama(text, system)

    def _polish_ollama(self, text: str, system: str) -> str:
        try:
            import ollama
            from whisprflow.config import OLLAMA_MODEL
            response = ollama.chat(
                model=OLLAMA_MODEL,
                messages=[
                    {"role": "system", "content": system},
                    {"role": "user", "content": text},
                ],
                options={"temperature": 0.1, "num_predict": 1024},
            )
            return response["message"]["content"].strip()
        except Exception as e:
            print(f"[WhisprFlow] Ollama error: {e}")
            return text
