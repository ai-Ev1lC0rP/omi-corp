"""Self-hosted pre-recorded STT for Offline Sync on single-host deployments.

Upstream sync transcribes each VAD segment by staging it in the GCS syncing bucket and
handing a signed URL to a cloud pre-recorded provider. A single-host deployment has
neither, so when ``SYNC_PRERECORDED_STT=whisper_gradio`` (and ``WHISPER_GRADIO_URL`` is
set) the segment WAV goes straight from local disk to the same Whisper-WebUI server the
live listen socket uses. Whisper-WebUI returns plain text, so the segment is reported as
one word group that spans the segment; ``postprocess_words`` splits long groups.
"""

from __future__ import annotations

import asyncio
import logging
import os
import wave
from typing import Any, Dict, List, Optional, Tuple

import httpx

logger = logging.getLogger(__name__)

SYNC_LOCAL_STT_PROVIDER = 'whisper_gradio'
SYNC_LOCAL_STT_MODEL = 'large-v3-turbo'  # mirrors utils.stt.whisper_gradio.WHISPER_GRADIO_MODEL
SYNC_LOCAL_STT_LANGUAGE = 'en'  # Whisper-WebUI's language is fixed by TRANSCRIBE_PARAMS
SYNC_LOCAL_STT_SERVICE: Tuple[str, None, str] = (SYNC_LOCAL_STT_PROVIDER, None, SYNC_LOCAL_STT_MODEL)

# utils.stt.whisper_gradio (numpy, the live STT socket stack) is imported lazily so the sync
# pipeline module stays importable wherever the live STT stack is stubbed or absent.


def _whisper_gradio_url() -> Optional[str]:
    url = (os.getenv('WHISPER_GRADIO_URL') or '').strip().rstrip('/')
    return url or None


async def transcribe_wav(client: httpx.AsyncClient, base_url: str, wav: bytes) -> str:
    from utils.stt.whisper_gradio import transcribe_wav as _transcribe_wav

    return await _transcribe_wav(client, base_url, wav)


def sync_local_stt_enabled() -> bool:
    return os.getenv('SYNC_PRERECORDED_STT', '').strip().lower() == 'whisper_gradio' and bool(_whisper_gradio_url())


def service_triple() -> Optional[Tuple[str, None, str]]:
    """``get_prerecorded_service``-shaped labels when local STT is on, else None."""
    return SYNC_LOCAL_STT_SERVICE if sync_local_stt_enabled() else None


def read_segment_bytes(path: str) -> Optional[bytes]:
    """Local-STT counterpart of the pipeline's signed-URL download: the segment never left disk."""
    try:
        with open(path, 'rb') as reader:
            return reader.read()
    except OSError as e:
        logger.warning('event=sync_local_audio_read outcome=failed exception_type=%s', type(e).__name__)
        return None


def _wav_duration_seconds(wav: bytes, path: str) -> float:
    try:
        with wave.open(path, 'rb') as reader:
            rate = reader.getframerate()
            return reader.getnframes() / float(rate) if rate else 0.0
    except (wave.Error, EOFError, OSError):
        # Header unreadable: fall back to PCM16 16 kHz mono after a 44-byte header.
        return max(0.0, (len(wav) - 44) / 32000.0)


async def _transcribe(base_url: str, wav: bytes, timeout: float) -> str:
    async with httpx.AsyncClient(timeout=timeout) as client:
        return await transcribe_wav(client, base_url, wav)


def transcribe_segment_words(path: str, timeout: float | None = None) -> List[Dict[str, Any]]:
    """Transcribe one local VAD segment WAV into ``prerecorded``-style word dicts.

    Runs on a sync executor thread (no running event loop), so ``asyncio.run`` is safe.
    Raises on transport/server errors so the caller records a retryable segment failure.
    """
    base_url = _whisper_gradio_url()
    if not base_url:
        raise RuntimeError('WHISPER_GRADIO_URL is not configured')
    if timeout is None:
        timeout = float(os.getenv('SYNC_WHISPER_GRADIO_TIMEOUT_SECONDS', '180') or 180)
    with open(path, 'rb') as reader:
        wav = reader.read()
    text = asyncio.run(_transcribe(base_url, wav, timeout)).strip()
    if text:
        from utils.stt.whisper_guards import filter_transcript

        # Same hallucination guard as the live socket ("Thank you.", repetition loops).
        text, reason = filter_transcript(text)
        if reason:
            logger.info('event=sync_local_stt_filtered reason=%s', reason)
    if not text:
        return []
    duration = _wav_duration_seconds(wav, path)
    return [{'timestamp': [0.0, round(max(duration, 0.1), 2)], 'speaker': 'SPEAKER_00', 'text': text}]


def transcribe_segment(path: str) -> Tuple[List[Dict[str, Any]], str]:
    """``prerecorded(..., return_language=True)``-shaped result for a local segment."""
    return transcribe_segment_words(path), SYNC_LOCAL_STT_LANGUAGE
