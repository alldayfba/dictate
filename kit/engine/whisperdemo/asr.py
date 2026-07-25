"""ASR backends for the WhisperShell engine.

One interface (`EngineASR`), two implementations:
  - PywhispercppASR : whisper.cpp + Metal, large-v3-turbo q8_0 (PRIMARY, confirmed
    Metal-engaged on M4 Max at ~0.26s warm for a 7s clip).
  - MlxWhisperASR   : mlx-whisper large-v3-turbo (FALLBACK, config flag "engine":"mlx").

Both take a warm-loaded model, an in-memory float32 mono-16k numpy array, and an
optional `initial_prompt` (dictionary hotwords). No WAV round-trip (fixes audit F9).

whisper.cpp's own logs are routed to a caller-supplied stream (stderr) so stdout
stays a clean JSON protocol channel.
"""
from __future__ import annotations

import sys
import time
from typing import Optional, TextIO

import numpy as np


class EngineASR:
    """Abstract ASR backend. Warm-load once, transcribe many."""

    name: str = "base"

    def load(self) -> None:  # pragma: no cover - interface
        raise NotImplementedError

    def transcribe(self, audio: np.ndarray, initial_prompt: Optional[str] = None) -> str:  # pragma: no cover
        raise NotImplementedError


class PywhispercppASR(EngineASR):
    name = "pywhispercpp"

    def __init__(
        self,
        model_name: str = "large-v3-turbo-q8_0",
        n_threads: int = 8,
        models_dir: Optional[str] = None,
        log_stream: Optional[TextIO] = None,
    ):
        self.model_name = model_name
        self.n_threads = n_threads
        self.models_dir = models_dir
        self._log_stream = log_stream if log_stream is not None else sys.stderr
        self._model = None

    def load(self) -> None:
        from pywhispercpp.model import Model

        # flash_attn + gpu default on; Metal is auto-selected on Apple Silicon.
        self._model = Model(
            self.model_name,
            models_dir=self.models_dir,
            n_threads=self.n_threads,
            redirect_whispercpp_logs_to=self._log_stream,
        )

    def transcribe(self, audio: np.ndarray, initial_prompt: Optional[str] = None) -> str:
        if self._model is None:
            self.load()
        audio = np.ascontiguousarray(audio, dtype=np.float32)
        kwargs = dict(
            language="en",
            print_progress=False,
            print_realtime=False,
            # greedy decoding is the default sampling strategy (fast, near-identical
            # to beam for dictation) — do not force beam search.
        )
        if initial_prompt:
            kwargs["initial_prompt"] = initial_prompt
        segments = self._model.transcribe(audio, **kwargs)
        return " ".join(seg.text for seg in segments).strip()


class MlxWhisperASR(EngineASR):
    name = "mlx"

    def __init__(self, model_repo: str = "mlx-community/whisper-large-v3-turbo"):
        self.model_repo = model_repo
        self._mlx = None

    def load(self) -> None:
        import mlx_whisper  # noqa: F401

        self._mlx = mlx_whisper
        # mlx-whisper lazy-loads/downloads the repo on first transcribe; warm it
        # with a tiny silent buffer so the first real dictation isn't cold.
        try:
            self._mlx.transcribe(
                np.zeros(16000, dtype=np.float32),
                path_or_hf_repo=self.model_repo,
                verbose=False,
            )
        except Exception:
            pass

    def transcribe(self, audio: np.ndarray, initial_prompt: Optional[str] = None) -> str:
        if self._mlx is None:
            self.load()
        audio = np.ascontiguousarray(audio, dtype=np.float32)
        kwargs = dict(path_or_hf_repo=self.model_repo, language="en", verbose=False)
        if initial_prompt:
            kwargs["initial_prompt"] = initial_prompt
        res = self._mlx.transcribe(audio, **kwargs)
        return (res.get("text") or "").strip()


def make_asr(engine: str, models_dir: Optional[str], log_stream: Optional[TextIO]) -> EngineASR:
    """Factory: 'mlx' → MLX fallback, anything else → pywhispercpp primary."""
    if (engine or "").lower() == "mlx":
        return MlxWhisperASR()
    return PywhispercppASR(models_dir=models_dir, log_stream=log_stream)
