"""Hallucination guards for the self-hosted Whisper live STT (``whisper_gradio``).

Whisper invents text for audio without speech: "Thank you.", "You", "Thanks for watching!",
music notes, or one phrase repeated in a loop. The live socket sends every energy-segmented
chunk, so a fan, a rustling sleeve or room tone turned into a transcript. Two cheap layers sit
on either side of the server call (the server's own Silero VAD is the third):

* :class:`SpeechGate` runs before upload. A 30 ms frame counts as voiced only when it is loud
  enough, WebRTC VAD (when importable) calls it speech, and it is periodic in the human pitch
  range (YIN). Broadband noise, room tone and clicks fail the periodicity test. A chunk is sent
  only with at least ``min_speech_s`` of such frames.
* :func:`filter_transcript` runs on the returned text. A chunk whose entire text is a known
  Whisper hallucination, punctuation or music notes, or a repetition loop, is dropped.

Both are pure functions of the chunk so they are unit-testable without a server.
"""

from __future__ import annotations

import importlib
import logging
import re
import unicodedata
from dataclasses import dataclass
from typing import Any, Callable, List, Optional, Sequence, Tuple

import numpy as np

logger = logging.getLogger(__name__)

FRAME_S = 0.03
_PITCH_MIN_HZ = 70.0
_PITCH_MAX_HZ = 400.0
_WEBRTC_RATES = (8000, 16000, 32000, 48000)


def _load_webrtc_vad(mode: int) -> Optional[Callable[[bytes, int], bool]]:
    """Return ``is_speech(frame, sample_rate)`` from webrtcvad, or None when unavailable.

    ``webrtcvad.py`` imports ``pkg_resources`` (setuptools), which slim images lack, so fall
    back to the C extension it wraps. Imported dynamically: neither ships type stubs.
    """
    try:
        module: Any = importlib.import_module('webrtcvad')
        vad = module.Vad(mode)
        return lambda frame, sample_rate: bool(vad.is_speech(frame, sample_rate))
    except Exception:
        pass
    try:
        ext: Any = importlib.import_module('_webrtcvad')
        handle = ext.create()
        ext.init(handle)
        ext.set_mode(handle, mode)
        return lambda frame, sample_rate: bool(ext.process(handle, sample_rate, frame, len(frame) // 2))
    except Exception:
        return None


@dataclass(frozen=True)
class GateResult:
    passed: bool
    speech_s: float  # loud frames WebRTC VAD calls speech
    voiced_s: float  # of those, frames that are also periodic in the pitch range
    frames: int
    webrtc: bool

    def describe(self) -> str:
        return (
            f'voiced={self.voiced_s:.2f}s speech={self.speech_s:.2f}s frames={self.frames} '
            f'webrtc={"on" if self.webrtc else "off"}'
        )


def yin_aperiodicity(frames: np.ndarray, sample_rate: int) -> np.ndarray:
    """Per-frame minimum of YIN's cumulative mean normalized difference over the pitch range.

    Near 0 for a periodic (voiced) frame, near or above 1 for noise. ``frames`` is
    ``(n_frames, frame_len)`` float32.
    """
    n_frames, frame_len = frames.shape
    tau_min = max(2, int(sample_rate / _PITCH_MAX_HZ))
    tau_max = min(frame_len // 2, int(sample_rate / _PITCH_MIN_HZ))
    if n_frames == 0 or tau_max <= tau_min:
        return np.ones(n_frames, dtype=np.float32)
    window = frame_len - tau_max
    x = frames - frames.mean(axis=1, keepdims=True)
    head = x[:, :window]
    diff = np.empty((n_frames, tau_max + 1), dtype=np.float32)
    diff[:, 0] = 0.0
    for tau in range(1, tau_max + 1):
        delta = head - x[:, tau : tau + window]
        diff[:, tau] = np.einsum('ij,ij->i', delta, delta)
    running = np.cumsum(diff[:, 1:], axis=1)
    taus = np.arange(1, tau_max + 1, dtype=np.float32)
    with np.errstate(divide='ignore', invalid='ignore'):
        cmndf = np.where(running > 0, diff[:, 1:] * taus / running, 1.0)
    return cmndf[:, tau_min - 1 : tau_max].min(axis=1)


class SpeechGate:
    """Decide whether a PCM16 chunk holds enough voiced speech to be worth transcribing."""

    def __init__(
        self,
        *,
        min_speech_s: float = 0.6,
        min_voiced_s: float = 0.3,
        min_rms: float = 300.0,
        max_aperiodicity: float = 0.35,
        webrtc_mode: int = 3,
        use_webrtc: bool = True,
    ) -> None:
        self.min_speech_s = min_speech_s
        self.min_voiced_s = min_voiced_s
        self.min_rms = min_rms
        self.max_aperiodicity = max_aperiodicity
        self._webrtc = _load_webrtc_vad(webrtc_mode) if use_webrtc else None

    @property
    def webrtc_available(self) -> bool:
        return self._webrtc is not None

    def evaluate(self, pcm: bytes, sample_rate: int) -> GateResult:
        frame_len = int(sample_rate * FRAME_S)
        samples = np.frombuffer(pcm[: len(pcm) - len(pcm) % 2], dtype='<i2')
        n_frames = samples.size // frame_len if frame_len else 0
        if n_frames == 0:
            return GateResult(False, 0.0, 0.0, 0, self._webrtc is not None)
        raw = samples[: n_frames * frame_len]
        frames = raw.astype(np.float32).reshape(n_frames, frame_len)
        rms = np.sqrt(np.mean(frames * frames, axis=1))
        loud = rms >= self.min_rms
        use_webrtc = self._webrtc is not None and sample_rate in _WEBRTC_RATES
        if use_webrtc:
            assert self._webrtc is not None
            frame_bytes = raw.astype('<i2').tobytes()
            step = frame_len * 2
            speech = np.array(
                [
                    bool(loud[i]) and self._webrtc(frame_bytes[i * step : (i + 1) * step], sample_rate)
                    for i in range(n_frames)
                ],
                dtype=bool,
            )
        else:
            speech = loud
        voiced = speech.copy()
        if voiced.any():
            idx = np.flatnonzero(voiced)
            voiced[idx] = yin_aperiodicity(frames[idx], sample_rate) <= self.max_aperiodicity
        speech_s = float(speech.sum()) * FRAME_S
        voiced_s = float(voiced.sum()) * FRAME_S
        passed = speech_s >= self.min_speech_s - 1e-9 and voiced_s >= self.min_voiced_s - 1e-9
        return GateResult(passed, round(speech_s, 3), round(voiced_s, 3), n_frames, use_webrtc)


# --------------------------------------------------------------------------- text filter

# Normalized (lowercase, ASCII apostrophes removed, punctuation stripped) whole-chunk outputs
# Whisper produces from silence, noise or music. Only an exact whole-chunk (or every-sentence)
# match is dropped, so "thank you for the coffee" is kept.
HALLUCINATION_PHRASES = frozenset(
    {
        'you',
        'thank you',
        'thank you very much',
        'thank you so much',
        'thanks',
        'thanks a lot',
        'thank you for watching',
        'thanks for watching',
        'thank you for watching and see you next time',
        'thanks for watching and see you next time',
        'thank you for listening',
        'thanks for listening',
        'please subscribe',
        'subscribe',
        'like and subscribe',
        'please like and subscribe',
        'dont forget to like and subscribe',
        'subscribe to my channel',
        'please subscribe to my channel',
        'see you next time',
        'ill see you next time',
        'i will see you next time',
        'see you in the next video',
        'see you in the next one',
        'bye',
        'bye bye',
        'goodbye',
        'im so excited to be here',
        'so',
        'oh',
        'uh',
        'um',
        'hmm',
        'mm',
        'mhm',
        'ah',
        'music',
        'applause',
        'laughter',
        'silence',
        'blank audio',
        'blankaudio',
        'inaudible',
        'no speech',
        'the end',
        'subtitles by the amaraorg community',
        'subtitles by the amara org community',
        'transcription by castingwords',
        'transcribed by',
        'translated by',
        'amaraorg',
    }
)

_SENTENCE_SPLIT = re.compile(r'[.!?…。！？]+')
_KEEP = re.compile(r"[^0-9a-z' ]+")


def normalize_text(text: str) -> str:
    folded = unicodedata.normalize('NFKD', text).encode('ascii', 'ignore').decode('ascii').lower()
    folded = folded.replace('_', ' ')
    folded = _KEEP.sub(' ', folded).replace("'", '')
    return ' '.join(folded.split())


def collapse_repeats(tokens: Sequence[str], *, min_repeats: int = 3, max_ngram: int = 12) -> List[str]:
    """Collapse runs of the same n-gram repeated ``min_repeats``+ times in a row to one copy."""
    out = list(tokens)
    changed = True
    while changed:
        changed = False
        for n in range(1, max_ngram + 1):
            i = 0
            while i + n * min_repeats <= len(out):
                gram = out[i : i + n]
                reps = 1
                while out[i + reps * n : i + (reps + 1) * n] == gram:
                    reps += 1
                if reps >= min_repeats:
                    out[i + n : i + reps * n] = []
                    changed = True
                i += 1
    return out


def filter_transcript(text: str, *, prompt: str = '', loop_coverage: float = 0.6) -> Tuple[str, Optional[str]]:
    """Return ``(text, None)`` to keep a chunk or ``('', reason)`` to drop it as a hallucination.

    ``prompt`` is the initial prompt sent with the chunk; text that is only (part of) the prompt
    is Whisper echoing it back for audio without speech.
    """
    normalized = normalize_text(text)
    if not normalized:
        return '', 'no_words'
    normalized_prompt = normalize_text(prompt)
    if normalized_prompt and f' {normalized} ' in f' {normalized_prompt} ':
        return '', 'prompt_echo'
    sentences = [s for s in (normalize_text(part) for part in _SENTENCE_SPLIT.split(text)) if s]
    if normalized in HALLUCINATION_PHRASES or (sentences and all(s in HALLUCINATION_PHRASES for s in sentences)):
        return '', 'known_hallucination'
    tokens = normalized.split()
    if len(tokens) >= 4:
        collapsed = collapse_repeats(tokens)
        if ' '.join(collapsed) in HALLUCINATION_PHRASES:
            return '', 'known_hallucination_loop'
        if 1 - len(collapsed) / len(tokens) >= loop_coverage:
            return '', 'repetition_loop'
    return text, None
