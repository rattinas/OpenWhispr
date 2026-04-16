"""Speech-to-text via Groq Cloud API or local mlx-whisper."""

import tempfile
import os
import time
import numpy as np
import soundfile as sf
from whisprflow import settings
from whisprflow.config import WHISPER_MODEL, SAMPLE_RATE


class Transcriber:
    def __init__(self):
        self._model_path = WHISPER_MODEL
        self._local_loaded = False

    def warm_up(self):
        if settings.get_stt_provider() != "local":
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

    def transcribe(self, audio: np.ndarray, prompt: str | None = None) -> str:
        if len(audio) == 0:
            return ""

        language = settings.get_language()
        if language == "auto":
            language = None

        provider = settings.get_stt_provider()
        groq_key = settings.get_groq_key()

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
