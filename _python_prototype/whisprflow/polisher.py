"""Text polishing via Anthropic Claude or Ollama."""

from whisprflow import settings
from whisprflow.config import OLLAMA_MODEL

# Built-in modes (always available, user can override prompts via custom modes)
BASE_INSTRUCTION = "WICHTIG: Behalte die Sprache des Inputs bei. Gib NUR den Ergebnistext aus — keine Erklärungen.\n\n"

DEFAULT_MODES = {
    "raw": {
        "label": "✏️ Raw (no polish)",
        "prompt": None,
    },
    "clean": {
        "label": "🧹 Clean",
        "prompt": BASE_INSTRUCTION + "Korrigiere nur Zeichensetzung und Gross-/Kleinschreibung. Entferne Füllwörter und Stotterer. Ändere sonst nichts.",
    },
    "professional": {
        "label": "💼 Professional",
        "prompt": BASE_INSTRUCTION + "Formuliere als klare, professionelle Kommunikation. Korrigiere Grammatik, entferne Füllwörter. Präzise und direkt.",
    },
    "marketing": {
        "label": "📣 Marketing",
        "prompt": BASE_INSTRUCTION + "Formuliere als überzeugende Marketing-Texte. Knackig, nutzenorientiert, ansprechend. Behalte die Kernaussage.",
    },
    "coding": {
        "label": "💻 Code Comment",
        "prompt": BASE_INSTRUCTION + "Formuliere als präzisen technischen Kommentar. Technische Fachsprache. Behalte alle technischen Begriffe exakt.",
    },
    "email": {
        "label": "📧 Email",
        "prompt": BASE_INSTRUCTION + "Formuliere als gut strukturierte E-Mail. Professioneller Ton, klare Absätze. Kurz und prägnant.",
    },
    "casual": {
        "label": "💬 Casual",
        "prompt": BASE_INSTRUCTION + "Bereinige für eine Chat-Nachricht. Locker, kurz und natürlich. Entferne Füllwörter, behalte informellen Ton.",
    },
}

DEFAULT_MODE = "clean"


def get_all_modes() -> dict:
    """Return merged dict of default + custom modes."""
    modes = dict(DEFAULT_MODES)
    custom = settings.load_custom_modes()
    for key, mode in custom.items():
        # Custom modes override defaults or add new
        modes[key] = {"label": mode["label"], "prompt": mode.get("prompt")}
    return modes


class Polisher:
    def __init__(self):
        self._mode = DEFAULT_MODE
        self._ollama_warmed = False

    @property
    def mode(self) -> str:
        return self._mode

    @mode.setter
    def mode(self, value: str):
        all_modes = get_all_modes()
        if value in all_modes:
            self._mode = value

    def warm_up(self):
        if settings.get_polish_provider() == "ollama" and not self._ollama_warmed:
            try:
                import ollama
                ollama.chat(model=OLLAMA_MODEL, messages=[{"role": "user", "content": "hi"}],
                            options={"num_predict": 1})
                self._ollama_warmed = True
            except Exception:
                pass

    def polish(self, raw_text: str, extra_context: str = "") -> str:
        if not raw_text.strip():
            return ""

        all_modes = get_all_modes()
        mode = all_modes.get(self._mode, all_modes.get(DEFAULT_MODE, {}))
        if mode.get("prompt") is None:
            return raw_text

        system = mode["prompt"]
        if extra_context:
            system += "\n" + extra_context

        provider = settings.get_polish_provider()
        api_key = settings.get_anthropic_key()

        if provider == "anthropic" and api_key:
            print(f"[WhisprFlow] Polish: Anthropic Claude [{self._mode}]")
            return self._polish_anthropic(raw_text, system, api_key)
        else:
            print(f"[WhisprFlow] Polish: Ollama [{self._mode}]")
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
