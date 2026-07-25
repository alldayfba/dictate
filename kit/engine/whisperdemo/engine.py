"""WhisperDemo python engine — headless ASR worker (demo build, red HUD shell).

Self-contained student kit build: all modules local to this package, all state
in ~/Library/Application Support/WhisperDemo/. Includes `cancel`, `stage`
events, frontmost-app context on `stop`, and the AI polish pass (rewrite.py).

Transport: newline-delimited JSON.
  stdin  = commands from the Swift shell
  stdout = protocol events to the shell  (JSON ONLY — nothing else may print here)
  stderr = diagnostics + whisper.cpp logs (shell captures to engine.log)

Protocol
--------
shell -> engine:
  {"t":"hello","config":{...}}          load model, warm up, reply "ready"
  {"t":"start","id":N}                  begin utterance N (clear audio accumulator)
  {"t":"audio","id":N,"pcm":"<b64f32>"} append audio frames
  {"t":"flush","id":N}                  live-preview partial -> "partial"
  {"t":"stop","id":N,"duration":F,
   "app_name":..,"bundle_id":..}        transcribe (+AI polish) -> "final"
  {"t":"cancel","id":N}                 drop the utterance, nothing pastes
  {"t":"ping","seq":N}                  -> "health"
  {"t":"stats_req"}                     -> "stats"
  {"t":"shutdown"}                      clean exit

engine -> shell:
  {"t":"ready","engine":..,"model":..,"load_ms":N}
  {"t":"partial","id":N,"text":..}
  {"t":"stage","id":N,"text":"Polishing…"}     pill label while the AI pass runs
  {"t":"final","id":N,"raw":..,"text":..,"paste":true}
  {"t":"health","seq":N,"ok":true,"state":"idle"}
  {"t":"error","id":N,"msg":..}
  {"t":"notify","text":..,"level":"info"}
  {"t":"stats","total":N,"today":N,"chars":N}
"""
from __future__ import annotations

import base64
import json
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FuturesTimeout
from typing import Optional

import numpy as np

from . import cleanup as cleanup_mod
from .asr import make_asr
from .dictionary import WhisperDictionary
from .history import TranscriptionHistory

from . import paths
from . import rewrite

SAMPLE_RATE = 16000
MIN_RECORDING_SECONDS = 0.5
TRANSCRIBE_TIMEOUT_S = 30.0   # stuck-transcription guard

_STDOUT = sys.stdout
_STDERR = sys.stderr
_EMIT_LOCK = threading.Lock()


def _emit(obj: dict) -> None:
    """Write one protocol event to stdout. The ONLY thing allowed on stdout."""
    try:
        with _EMIT_LOCK:
            _STDOUT.write(json.dumps(obj, ensure_ascii=False) + "\n")
            _STDOUT.flush()
    except Exception:
        pass


def _log(msg: str) -> None:
    """Diagnostics go to stderr (shell captures to engine.log). Never stdout."""
    try:
        _STDERR.write(f"[engine] {msg}\n")
        _STDERR.flush()
    except Exception:
        pass


class Engine:
    def __init__(self) -> None:
        self.config = self._load_config()
        self.cleanup_mode = self.config.get("cleanup_mode", "regex")
        self.ai_cfg = self.config.get("ai", {}) or {}

        self.dictionary = WhisperDictionary(path=paths.dictionary_path())
        self.history = TranscriptionHistory(db_path=paths.history_db_path())

        self._asr = None
        self._pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="asr")
        self._buf: list[np.ndarray] = []
        self._cur_id: int = -1
        self._state: str = "loading"
        self._flushing: bool = False   # a live-preview partial transcription is in flight
        self._cancelled_id: int = -1   # utterance cancelled by the user (Esc)

    # ---- config ---------------------------------------------------------
    def _load_config(self) -> dict:
        try:
            p = paths.config_path()
            if p.exists():
                return json.loads(p.read_text())
        except Exception as e:
            _log(f"config load failed, using defaults: {e}")
        return {}

    def _apply_hello_config(self, cfg: Optional[dict]) -> None:
        if not cfg:
            return
        self.config.update(cfg)
        self.cleanup_mode = self.config.get("cleanup_mode", self.cleanup_mode)
        # "ai" intentionally comes ONLY from config.json (menu toggle rewrites the
        # file and restarts us) — hello never carries it, so no staleness.

    # ---- ASR lifecycle --------------------------------------------------
    def _build_and_warm_asr(self) -> None:
        engine_name = self.config.get("engine", "pywhispercpp")
        models_dir = str(paths.models_dir())
        t0 = time.time()
        self._asr = make_asr(engine_name, models_dir=models_dir, log_stream=_STDERR)
        self._asr.load()
        # warm the graph with a short silent buffer so the first real clip is hot
        try:
            self._asr.transcribe(np.zeros(SAMPLE_RATE // 2, dtype=np.float32))
        except Exception as e:
            _log(f"warm run note: {e}")
        load_ms = int((time.time() - t0) * 1000)
        self._state = "idle"
        _emit(
            {
                "t": "ready",
                "engine": self._asr.name,
                "model": getattr(self._asr, "model_name", self._asr.name),
                "load_ms": load_ms,
            }
        )
        ai_on = (self.ai_cfg.get("mode", "on") == "on")
        _log(f"ready: engine={self._asr.name} load_ms={load_ms} ai={'on' if ai_on else 'off'}")

    # ---- audio ----------------------------------------------------------
    @staticmethod
    def _decode_pcm(b64: str) -> np.ndarray:
        return np.frombuffer(base64.b64decode(b64), dtype="<f4").astype(np.float32)

    def _handle_start(self, msg: dict) -> None:
        self._cur_id = int(msg.get("id", -1))
        self._buf = []
        self._state = "recording"

    def _handle_audio(self, msg: dict) -> None:
        pcm = msg.get("pcm")
        if not pcm:
            return
        try:
            self._buf.append(self._decode_pcm(pcm))
        except Exception as e:
            _log(f"audio decode error: {e}")

    def _handle_cancel(self, msg: dict) -> None:
        uid = int(msg.get("id", self._cur_id))
        self._cancelled_id = uid
        self._buf = []
        self._state = "idle"
        _log(f"cancel id={uid} — buffer dropped")

    def _handle_flush(self, msg: dict) -> None:
        """Live-preview: transcribe the audio accumulated so far and emit a raw
        partial. Fire-and-forget on the worker pool; skipped if one is already in
        flight or the buffer is too short. No cleanup/dictionary — speed over polish."""
        if self._flushing or self._state != "recording":
            return
        snapshot = list(self._buf)
        if not snapshot:
            return
        audio = np.concatenate(snapshot, axis=0).astype(np.float32)
        if audio.shape[0] < SAMPLE_RATE * 0.4:   # <0.4s, nothing worth previewing yet
            return
        uid = int(msg.get("id", self._cur_id))
        self._flushing = True

        def _work():
            try:
                prompt = self.dictionary.get_hotwords_prompt() or None
                text = (self._asr.transcribe(audio, prompt) or "").strip()
                if text:
                    _emit({"t": "partial", "id": uid, "text": text})
            except Exception as e:
                _log(f"flush error: {e}")
            finally:
                self._flushing = False

        try:
            self._pool.submit(_work)
        except Exception:
            self._flushing = False

    def _handle_stop(self, msg: dict) -> None:
        uid = int(msg.get("id", self._cur_id))
        duration = float(msg.get("duration", 0.0))
        app_name = msg.get("app_name")
        self._state = "transcribing"
        try:
            if self._cancelled_id == uid or not self._buf:
                self._finish_empty(uid)
                return
            audio = np.concatenate(self._buf, axis=0).astype(np.float32)
            self._buf = []
            if duration < MIN_RECORDING_SECONDS or audio.shape[0] < SAMPLE_RATE * MIN_RECORDING_SECONDS:
                self._finish_empty(uid)
                return

            prompt = self.dictionary.get_hotwords_prompt() or None
            try:
                fut = self._pool.submit(self._asr.transcribe, audio, prompt)
                raw = fut.result(timeout=TRANSCRIBE_TIMEOUT_S)
            except FuturesTimeout:
                _log("transcription timed out (stuck-guard fired)")
                _emit({"t": "error", "id": uid, "msg": "transcription timeout"})
                self._state = "idle"
                return

            raw = (raw or "").strip()
            if not raw:
                _emit({"t": "notify", "text": "No speech detected", "level": "info"})
                self._finish_empty(uid)
                return

            cleaned = cleanup_mod.clean_transcript(raw, mode=self.cleanup_mode)
            cleaned = self.dictionary.apply(cleaned)

            # ---- AI polish pass (Wisprflow parity) — can never lose a dictation:
            # any failure/timeout/garbage → the regex-cleaned text pastes instead.
            if self.ai_cfg.get("mode", "on") == "on" and rewrite.needs_polish(raw):
                _emit({"t": "stage", "id": uid, "text": "Polishing…"})
                t0 = time.time()
                polished = rewrite.polish(cleaned, app_name, self.ai_cfg, log=_log)
                if polished:
                    _log(f"rewrite: ok in {time.time() - t0:.1f}s "
                         f"({len(cleaned)}→{len(polished)} chars, app={app_name or '?'})")
                    cleaned = polished

            # Esc may have arrived while we were transcribing/polishing — honor it.
            if self._cancelled_id == uid:
                _log(f"final suppressed: id={uid} was cancelled during processing")
                self._finish_empty(uid)
                return

            try:
                self.history.save(duration, raw, cleaned)
            except Exception as e:
                _log(f"history save failed: {e}")
                self._emergency_save(cleaned)

            _emit({"t": "final", "id": uid, "raw": raw, "text": cleaned, "paste": True})
            _log(f"final id={uid} chars={len(cleaned)} app={app_name or '?'}")
        except Exception as e:
            _log(f"stop handler error: {e!r}")
            _emit({"t": "error", "id": uid, "msg": str(e)})
        finally:
            self._state = "idle"

    def _finish_empty(self, uid: int) -> None:
        _emit({"t": "final", "id": uid, "raw": "", "text": "", "paste": False})
        self._state = "idle"

    def _emergency_save(self, text: str) -> None:
        try:
            path = paths.state_dir() / f"emergency_{int(time.time())}.txt"
            path.write_text(text)
            _log(f"emergency save: {path}")
        except Exception:
            pass

    # ---- other commands -------------------------------------------------
    def _handle_stats(self) -> None:
        try:
            s = self.history.stats() or {}
        except Exception:
            s = {}
        _emit(
            {
                "t": "stats",
                "total": int(s.get("total_count", s.get("total", 0)) or 0),
                "today": int(s.get("today_count", s.get("today", 0)) or 0),
                "chars": int(s.get("total_chars", s.get("chars", 0)) or 0),
            }
        )

    # ---- main loop ------------------------------------------------------
    def run(self) -> None:
        for raw_line in sys.stdin:
            line = raw_line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except Exception:
                _log(f"bad json: {line[:120]}")
                continue

            t = msg.get("t")
            if t == "hello":
                self._apply_hello_config(msg.get("config"))
                try:
                    self._build_and_warm_asr()
                except Exception as e:
                    _log(f"model load failed: {e!r}")
                    _emit({"t": "error", "id": -1, "msg": f"model load failed: {e}"})
            elif t == "ping":
                _emit({"t": "health", "seq": msg.get("seq"), "ok": True, "state": self._state})
            elif t == "start":
                self._handle_start(msg)
            elif t == "audio":
                self._handle_audio(msg)
            elif t == "flush":
                self._handle_flush(msg)
            elif t == "stop":
                self._handle_stop(msg)
            elif t == "cancel":
                self._handle_cancel(msg)
            elif t == "stats_req":
                self._handle_stats()
            elif t == "shutdown":
                _log("shutdown requested")
                break
            else:
                _log(f"unknown message type: {t}")

        self._pool.shutdown(wait=False, cancel_futures=True)


def main() -> None:
    # Keep stdout as the JSON protocol channel ONLY. Any stray print() from ported
    # modules must not corrupt it — route them to stderr.
    sys.stdout = _STDERR
    try:
        Engine().run()
    except KeyboardInterrupt:
        pass
    except Exception as e:  # never die silently
        _log(f"fatal: {e!r}")
        _emit({"t": "error", "id": -1, "msg": f"fatal: {e}"})
        sys.exit(1)


if __name__ == "__main__":
    main()
