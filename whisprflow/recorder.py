"""Audio recording via sounddevice."""

import numpy as np
import sounddevice as sd
from whisprflow.config import SAMPLE_RATE, CHANNELS, DTYPE, BLOCKSIZE


class Recorder:
    def __init__(self):
        self._chunks: list[np.ndarray] = []
        self._stream: sd.InputStream | None = None
        self._device: int | None = None  # None = system default

    def set_device(self, device_index: int | None):
        self._device = device_index

    def start(self):
        self._chunks = []
        self._stream = sd.InputStream(
            samplerate=SAMPLE_RATE,
            channels=CHANNELS,
            dtype=DTYPE,
            blocksize=BLOCKSIZE,
            device=self._device,
            latency="low",
            callback=self._callback,
        )
        self._stream.start()

    def _callback(self, indata, frames, time_info, status):
        self._chunks.append(indata.copy())

    def stop(self) -> np.ndarray:
        if self._stream:
            self._stream.stop()
            self._stream.close()
            self._stream = None
        if not self._chunks:
            return np.array([], dtype=np.float32)
        return np.concatenate(self._chunks, axis=0).flatten()
