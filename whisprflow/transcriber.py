"""Speech-to-text via Groq Cloud API or local mlx-whisper."""

import tempfile
import os
import time
import json
import numpy as np
import soundfile as sf
from whisprflow.config import WHISPER_MODEL, SAMPLE_RATE, DATA_DIR

SETTINGS_PATH = os.path.join(DATA_DIR, "settings.json")


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


def get_groq_key() -> str | None:
    return _load_settings().get("groq_api_key")


def save_groq_key(key: str):
    s = _load_settings()
    s["groq_api_key"] = key
    _save_settings(s)


def get_stt_provider() -> str:
    return _load_settings().get("stt_provider", "local")


def save_stt_provider(provider: str):
    s = _load_settings()
    s["stt_provider"] = provider
    _save_settings(s)


class Transcriber:
    def __init__(self):
        self._model_path = WHISPER_MODEL
        self._local_loaded = False

    def warm_up(self):
        """Pre-load local model if using local provider."""
        if get_stt_provider() != "local":
            return
        if self._local_loaded:
            return
        import mlx_whisper
        silence = np.zeros(SAMPLE_RATE, dtype=np.float32)
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
            tmp = f.name
            sf.write(tmp, silence, SAMPLE_RATE)
        try:
            mlx_whisper.transcribe(tmp, path_or_hf_repo=self._model_path, language="en")
        finally:
            os.unlink(tmp)
        self._local_loaded = True

    def transcribe(self, audio: np.ndarray, language: str | None = None, prompt: str | None = None) -> str:
        if len(audio) == 0:
            return ""

        provider = get_stt_provider()
        groq_key = get_groq_key()

        if provider == "groq" and groq_key:
            return self._transcribe_groq(audio, language, prompt, groq_key)
        else:
            return self._transcribe_local(audio, language, prompt)

    def _transcribe_groq(self, audio: np.ndarray, language: str | None, prompt: str | None, api_key: str) -> str:
        from groq import Groq

        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
            tmp_path = f.name
            sf.write(tmp_path, audio, SAMPLE_RATE)

        try:
            client = Groq(api_key=api_key)
            start = time.time()

            with open(tmp_path, "rb") as audio_file:
                kwargs = {
                    "file": ("recording.wav", audio_file),
                    "model": "whisper-large-v3",
                    "response_format": "text",
                }
                if language:
                    kwargs["language"] = language
                if prompt:
                    kwargs["prompt"] = prompt

                result = client.audio.transcriptions.create(**kwargs)

            elapsed = time.time() - start
            text = result.strip() if isinstance(result, str) else result.text.strip()
            print(f"[WhisprFlow] Groq STT: {elapsed:.2f}s")
            return text
        except Exception as e:
            print(f"[WhisprFlow] Groq error: {e}, falling back to local")
            return self._transcribe_local(audio, language, prompt)
        finally:
            os.unlink(tmp_path)

    def _transcribe_local(self, audio: np.ndarray, language: str | None, prompt: str | None) -> str:
        import mlx_whisper

        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
            tmp_path = f.name
            sf.write(tmp_path, audio, SAMPLE_RATE)

        try:
            kwargs = {"path_or_hf_repo": self._model_path}
            if language:
                kwargs["language"] = language
            if prompt:
                kwargs["initial_prompt"] = prompt

            start = time.time()
            result = mlx_whisper.transcribe(tmp_path, **kwargs)
            elapsed = time.time() - start
            print(f"[WhisprFlow] Local STT: {elapsed:.1f}s")
            return result.get("text", "").strip()
        finally:
            os.unlink(tmp_path)
