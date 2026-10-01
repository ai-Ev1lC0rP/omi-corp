"""Live STT backed by a self-hosted Whisper-WebUI (jhj0517, Gradio 5) server.

Whisper-WebUI is file-in/text-out only, so this socket turns the live PCM16 stream into
utterance-sized WAV chunks with a lightweight energy segmenter and transcribes each chunk
through the three Gradio HTTP calls:

1. ``POST /gradio_api/upload`` (multipart ``files``) -> ``["<server path>"]``
2. ``POST /gradio_api/call/transcribe_file`` -> ``{"event_id": ...}``
3. ``GET /gradio_api/call/transcribe_file/<event_id>`` -> SSE; ``event: complete`` carries the text

Enabled by ``WHISPER_GRADIO_URL``. A failed chunk is logged and skipped; it never kills the
listen socket. Every call leaves a .wav/.txt in the server's GRADIO_TEMP_DIR.
"""

from __future__ import annotations

import asyncio
import io
import json
import logging
import os
import time
import wave
from dataclasses import dataclass
from typing import Any, Callable, Dict, List, Optional, Tuple

import httpx
import numpy as np

from utils.async_tasks import create_named_task
from config.stt_provider_policy import normalized_stt_language
from utils.stt.socket import STTSocket
from utils.stt.streaming import STTService

logger = logging.getLogger(__name__)

WHISPER_GRADIO_MODEL = 'large-v3-turbo'

# Positional parameters after the file list for Whisper-WebUI's /transcribe_file, copied
# verbatim from the voicemail workflow: txt output, large-v3-turbo, english, float16, cuda,
# Silero VAD on, diarization and BGM separation off. Index 44 (hf_token) stays empty.
TRANSCRIBE_PARAMS: Tuple[Any, ...] = (
    "",
    False,
    True,
    "txt",
    False,
    "large-v3-turbo",
    "english",
    False,
    5,
    -1,
    0.6,
    "float16",
    5,
    1,
    True,
    0.5,
    "",
    0,
    2.4,
    1,
    1,
    0,
    "",
    True,
    "[-1]",
    1,
    False,
    "\"'“¿([{-",
    "\"'.。,，!！?？:：”)]}、",
    0,
    30,
    0,
    "",
    0.5,
    1,
    24,
    True,
    False,
    0.5,
    250,
    9999,
    1000,
    2000,
    False,
    "cuda",
    "",
    False,
    False,
    "UVR-MDX-NET-Inst_HQ_4",
    "cuda",
    256,
    False,
    True,
)
assert len(TRANSCRIBE_PARAMS) == 53


class WhisperGradioError(RuntimeError):
    """One chunk could not be transcribed; the session keeps going."""


def whisper_gradio_url() -> Optional[str]:
    url = (os.getenv('WHISPER_GRADIO_URL') or '').strip().rstrip('/')
    return url or None


def whisper_gradio_live_selection(language: Optional[str]) -> Optional[Tuple[STTService, str, str]]:
    """Live-session provider override for deployments that set ``WHISPER_GRADIO_URL``.

    Returns the ``(service, language, model)`` triple ``get_stt_service_for_language`` would,
    or None to fall through to the policy-owned selection. Only the live listen socket calls
    this; push-to-talk and pre-recorded transcription keep their own providers. The server's
    model and language are fixed by ``TRANSCRIBE_PARAMS``.
    """
    if not whisper_gradio_url():
        return None
    return STTService.whisper_gradio, normalized_stt_language(language) or 'en', WHISPER_GRADIO_MODEL


def _env_float(name: str, default: float) -> float:
    try:
        return float(os.getenv(name, '') or default)
    except ValueError:
        return default


# --------------------------------------------------------------------------- payload / parsing


def pcm16_to_wav(pcm: bytes, sample_rate: int) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sample_rate)
        w.writeframes(pcm)
    return buf.getvalue()


def build_transcribe_payload(server_path: str) -> Dict[str, Any]:
    return {'data': [[{'path': server_path, 'meta': {'_type': 'gradio.FileData'}}], *TRANSCRIBE_PARAMS]}


def parse_upload_response(loaded: Any) -> str:
    if isinstance(loaded, list) and loaded and isinstance(loaded[0], str) and loaded[0]:
        return loaded[0]
    raise WhisperGradioError(f'upload returned no file path: {str(loaded)[:200]}')


def parse_sse_events(body: str) -> List[Tuple[str, str]]:
    """Split a Gradio SSE body into ``(event, data)`` pairs (multi-line data joined by \\n)."""
    events: List[Tuple[str, str]] = []
    for block in body.replace('\r\n', '\n').split('\n\n'):
        event = ''
        data_lines: List[str] = []
        for line in block.split('\n'):
            if line.startswith('event:'):
                event = line[6:].strip()
            elif line.startswith('data:'):
                data_lines.append(line[5:][1:] if line[5:].startswith(' ') else line[5:])
        if event or data_lines:
            events.append((event, '\n'.join(data_lines)))
    return events


def clean_result_text(raw: str) -> str:
    """Strip Whisper-WebUI's "Done in N seconds!" header and per-file "-----" banners."""
    lines = raw.replace('\r\n', '\n').split('\n')
    if lines and lines[0].strip().startswith('Done in'):
        lines = lines[1:]
    out: List[str] = []
    skip_next = False
    for line in lines:
        s = line.strip()
        if skip_next:
            skip_next = False
            continue
        if len(s) >= 10 and set(s) == {'-'}:
            skip_next = True  # the banner is followed by the source file name
            continue
        if s:
            out.append(s)
    return ' '.join(out).strip()


def extract_transcript(sse_body: str) -> str:
    events = parse_sse_events(sse_body)
    complete = [data for event, data in events if event == 'complete']
    if complete:
        try:
            loaded = json.loads(complete[-1])
        except json.JSONDecodeError as error:
            raise WhisperGradioError(f'complete data is not JSON: {complete[-1][:200]}') from error
        first = loaded[0] if isinstance(loaded, list) and loaded else loaded
        return clean_result_text('' if first is None else str(first))
    for event, data in events:
        if event == 'error':
            detail = data if data and data != 'null' else 'no details (check the Whisper-WebUI console)'
            raise WhisperGradioError(f'event: error: {detail[:300]}')
    raise WhisperGradioError(f'no "event: complete" in response: {sse_body[:300]}')


async def transcribe_wav(client: httpx.AsyncClient, base_url: str, wav: bytes) -> str:
    resp = await client.post(f'{base_url}/gradio_api/upload', files={'files': ('omi-chunk.wav', wav, 'audio/wav')})
    resp.raise_for_status()
    server_path = parse_upload_response(resp.json())
    resp = await client.post(f'{base_url}/gradio_api/call/transcribe_file', json=build_transcribe_payload(server_path))
    resp.raise_for_status()
    event_id = resp.json().get('event_id') if isinstance(resp.json(), dict) else None
    if not event_id:
        raise WhisperGradioError(f'transcribe_file returned no event_id: {resp.text[:200]}')
    resp = await client.get(f'{base_url}/gradio_api/call/transcribe_file/{event_id}')
    resp.raise_for_status()
    return extract_transcript(resp.text)


# --------------------------------------------------------------------------- segmentation


@dataclass
class Utterance:
    start: float  # seconds since the first audio byte of the session
    pcm: bytes
    sample_rate: int

    @property
    def duration(self) -> float:
        return len(self.pcm) / 2 / self.sample_rate

    @property
    def end(self) -> float:
        return self.start + self.duration


class UtteranceSegmenter:
    """Energy-based utterance chunker for mono PCM16.

    Works on 30 ms frames. A frame is speech when its RMS exceeds both ``min_rms`` and a
    multiple of the tracked noise floor. An utterance (with ``pre_roll`` of lead-in) is closed
    after ``silence_s`` of trailing silence, or when it reaches ``max_s`` it is split at the
    quietest frame of its last ``split_search_s`` (so long monologues are not cut mid-word) and
    the remainder carries into the next chunk. Chunks with less than ``min_speech_s`` of voiced
    audio are dropped as noise.
    """

    FRAME_S = 0.03

    def __init__(
        self,
        sample_rate: int,
        *,
        max_s: float = 12.0,
        silence_s: float = 0.7,
        pre_roll_s: float = 0.3,
        min_speech_s: float = 0.25,
        min_rms: float = 300.0,
        noise_ratio: float = 2.5,
        split_search_s: float = 2.0,
    ) -> None:
        self.sample_rate = sample_rate
        self.frame_bytes = int(sample_rate * self.FRAME_S) * 2
        self.max_frames = max(2, int(max_s / self.FRAME_S))
        self.silence_frames = max(1, int(silence_s / self.FRAME_S))
        self.pre_roll_frames = int(pre_roll_s / self.FRAME_S)
        self.min_speech_frames = max(1, int(min_speech_s / self.FRAME_S))
        self.split_search_frames = max(1, min(self.max_frames - 1, int(split_search_s / self.FRAME_S)))
        self.min_rms = min_rms
        self.noise_ratio = noise_ratio
        self.noise_floor = min_rms / noise_ratio
        self._pending = bytearray()
        self._frames_seen = 0  # frames consumed since session start
        self._pre_roll: List[bytes] = []
        self._utt: List[bytes] = []
        self._utt_rms: List[float] = []
        self._utt_speech: List[bool] = []
        self._utt_start_frame = 0
        self._trailing_silence = 0

    def _classify(self, frame: bytes) -> Tuple[bool, float]:
        samples = np.frombuffer(frame, dtype='<i2').astype(np.float32)
        rms = float(np.sqrt(np.mean(samples * samples))) if samples.size else 0.0
        speech = rms >= max(self.min_rms, self.noise_floor * self.noise_ratio)
        # Noise-floor tracker: falls quickly to quiet frames and creeps up ~5%/s otherwise, so
        # a steady loud background (fan, car) stops reading as endless speech within a minute.
        if rms < self.noise_floor:
            self.noise_floor = 0.9 * self.noise_floor + 0.1 * rms
        else:
            self.noise_floor *= 1.0015
        return speech, rms

    def _emit(self, start_frame: int, frames: List[bytes], speech_frames: int) -> Optional[Utterance]:
        if speech_frames < self.min_speech_frames or not frames:
            return None
        return Utterance(start=start_frame * self.FRAME_S, pcm=b''.join(frames), sample_rate=self.sample_rate)

    def _reset(self) -> None:
        self._utt, self._utt_rms, self._utt_speech, self._trailing_silence = [], [], [], 0

    def _close(self, trim_trailing: bool) -> Optional[Utterance]:
        n = len(self._utt)
        if trim_trailing and self._trailing_silence > 0:
            n -= self._trailing_silence - min(self._trailing_silence, int(0.2 / self.FRAME_S))
        utt = self._emit(self._utt_start_frame, self._utt[:n], sum(self._utt_speech[:n]))
        self._reset()
        return utt

    def _split_long(self) -> Optional[Utterance]:
        lo = len(self._utt) - self.split_search_frames
        cut = min(range(lo, len(self._utt)), key=lambda i: self._utt_rms[i]) + 1
        utt = self._emit(self._utt_start_frame, self._utt[:cut], sum(self._utt_speech[:cut]))
        self._utt_start_frame += cut
        self._utt, self._utt_rms, self._utt_speech = self._utt[cut:], self._utt_rms[cut:], self._utt_speech[cut:]
        self._trailing_silence = 0
        for speech in reversed(self._utt_speech):
            if speech:
                break
            self._trailing_silence += 1
        if not any(self._utt_speech):
            self._reset()
        return utt

    def push(self, pcm: bytes) -> List[Utterance]:
        out: List[Utterance] = []
        self._pending.extend(pcm)
        while len(self._pending) >= self.frame_bytes:
            frame = bytes(self._pending[: self.frame_bytes])
            del self._pending[: self.frame_bytes]
            speech, rms = self._classify(frame)
            if not self._utt:
                if speech:
                    self._utt = self._pre_roll + [frame]
                    self._utt_rms = [0.0] * len(self._pre_roll) + [rms]
                    self._utt_speech = [False] * len(self._pre_roll) + [True]
                    self._utt_start_frame = self._frames_seen - len(self._pre_roll)
                    self._pre_roll, self._trailing_silence = [], 0
                elif self.pre_roll_frames:
                    self._pre_roll.append(frame)
                    del self._pre_roll[: -self.pre_roll_frames]
            else:
                self._utt.append(frame)
                self._utt_rms.append(rms)
                self._utt_speech.append(speech)
                self._trailing_silence = 0 if speech else self._trailing_silence + 1
                utt: Optional[Utterance] = None
                if self._trailing_silence >= self.silence_frames:
                    utt = self._close(trim_trailing=True)
                elif len(self._utt) >= self.max_frames:
                    utt = self._split_long()
                if utt:
                    out.append(utt)
            self._frames_seen += 1
        return out

    def flush(self) -> List[Utterance]:
        """Close the open utterance (pending sub-frame audio is included)."""
        if self._utt and self._pending:
            self._utt.append(bytes(self._pending))
            self._utt_rms.append(0.0)
            self._utt_speech.append(False)
        self._pending.clear()
        self._pre_roll = []
        if not self._utt:
            return []
        utt = self._close(trim_trailing=False)
        return [utt] if utt else []


# --------------------------------------------------------------------------- socket

_SENTINEL: Any = object()


class WhisperGradioSocket(STTSocket):
    """STTSocket that segments live PCM16 and transcribes utterances via Whisper-WebUI.

    ``send`` is synchronous and cheap (framing + RMS); transcription runs in one background
    worker so the listen receive loop is never blocked. Chunks are transcribed in order.
    """

    def __init__(
        self,
        stream_transcript: Callable[[List[Dict[str, Any]]], None],
        base_url: str,
        sample_rate: int,
        *,
        segmenter: Optional[UtteranceSegmenter] = None,
        client: Optional[httpx.AsyncClient] = None,
        chunk_timeout_s: Optional[float] = None,
        max_queue: Optional[int] = None,
    ) -> None:
        self._stream_transcript = stream_transcript
        self._base_url = base_url.rstrip('/')
        self._sample_rate = sample_rate
        self._segmenter = segmenter or UtteranceSegmenter(
            sample_rate,
            max_s=_env_float('WHISPER_GRADIO_MAX_CHUNK_SECONDS', 12.0),
            silence_s=_env_float('WHISPER_GRADIO_SILENCE_SECONDS', 0.7),
            min_rms=_env_float('WHISPER_GRADIO_MIN_RMS', 300.0),
        )
        self._chunk_timeout_s = chunk_timeout_s or _env_float('WHISPER_GRADIO_CHUNK_TIMEOUT_SECONDS', 30.0)
        self._owns_client = client is None
        self._client = client or httpx.AsyncClient(timeout=httpx.Timeout(20.0, connect=5.0))
        self._queue: asyncio.Queue[Any] = asyncio.Queue()
        # Apple Watch / offline replays arrive in bursts; ~120 chunks is ~24 min of speech.
        self._max_queue = max_queue or int(_env_float('WHISPER_GRADIO_MAX_QUEUE', 120))
        self._worker: Optional[asyncio.Task[None]] = None
        self._closed = False
        self._dead = False
        self._dead_reason: Optional[str] = None
        self.chunks_ok = 0
        self.chunks_failed = 0

    def start(self) -> None:
        self._worker = create_named_task(self._run(), name='whisper_gradio_stt_worker')

    def _enqueue(self, utterances: List[Utterance]) -> None:
        for utt in utterances:
            if self._queue.qsize() >= self._max_queue:
                self.chunks_failed += 1
                logger.warning('Whisper-Gradio queue full; dropping %.1fs chunk at %.1fs', utt.duration, utt.start)
                continue
            self._queue.put_nowait(utt)

    # STTSocket interface (sync)
    def send(self, data: bytes) -> bool:
        if self._closed or self._dead:
            return False
        if data:
            self._enqueue(self._segmenter.push(data))
        return True

    def finalize(self) -> None:
        if not self._closed and not self._dead:
            self._enqueue(self._segmenter.flush())

    def finish(self) -> None:
        if self._closed:
            return
        self._enqueue(self._segmenter.flush())
        self._closed = True
        self._queue.put_nowait(_SENTINEL)

    @property
    def is_connection_dead(self) -> bool:
        return self._dead

    @property
    def death_reason(self) -> Optional[str]:
        return self._dead_reason

    async def drain_and_close(self, timeout: float = 45.0) -> None:
        """Transcribe the tail inline so its segments reach the session before teardown."""
        self.finish()
        worker = self._worker
        if worker is not None and not worker.done():
            try:
                await asyncio.wait_for(asyncio.shield(worker), timeout=timeout)
            except asyncio.TimeoutError:
                logger.warning('Whisper-Gradio drain timed out; %d chunk(s) dropped', self._queue.qsize())
                worker.cancel()
            except asyncio.CancelledError:
                worker.cancel()
                raise
        await self._close_client()

    async def _close_client(self) -> None:
        if self._owns_client:
            try:
                await self._client.aclose()
            except Exception:
                pass

    async def _run(self) -> None:
        try:
            while True:
                item = await self._queue.get()
                if item is _SENTINEL:
                    break
                await self._process(item)
        except asyncio.CancelledError:
            raise
        except Exception as error:  # a crashed worker would silently stop transcription
            logger.exception('Whisper-Gradio worker crashed')
            self._dead = True
            self._dead_reason = f'whisper_gradio worker crashed: {type(error).__name__}'
        finally:
            if self._closed:
                await self._close_client()

    async def _process(self, utt: Utterance) -> None:
        t0 = time.monotonic()
        try:
            text = await asyncio.wait_for(
                transcribe_wav(self._client, self._base_url, pcm16_to_wav(utt.pcm, utt.sample_rate)),
                timeout=self._chunk_timeout_s,
            )
        except Exception as error:
            self.chunks_failed += 1
            logger.warning(
                'Whisper-Gradio chunk failed (%.1fs audio at %.1fs) after %.2fs: %s: %s',
                utt.duration,
                utt.start,
                time.monotonic() - t0,
                type(error).__name__,
                str(error)[:200],
            )
            return
        self.chunks_ok += 1
        logger.info(
            'Whisper-Gradio chunk %.1fs audio at %.1fs transcribed in %.2fs (%d chars)',
            utt.duration,
            utt.start,
            time.monotonic() - t0,
            len(text),
        )
        if not text:
            return
        segment = {
            'speaker': 'SPEAKER_00',
            'start': round(utt.start, 3),
            'end': round(utt.end, 3),
            'text': text,
            'is_user': False,
            'person_id': None,
        }
        try:
            self._stream_transcript([segment])
        except Exception:
            logger.exception('Whisper-Gradio transcript callback failed')


async def process_audio_whisper_gradio(
    stream_transcript: Callable[[List[Dict[str, Any]]], None],
    sample_rate: int,
) -> Optional[WhisperGradioSocket]:
    base_url = whisper_gradio_url()
    if not base_url:
        logger.error('process_audio_whisper_gradio: WHISPER_GRADIO_URL not set')
        return None
    logger.info('process_audio_whisper_gradio sample_rate=%s -> %s', sample_rate, base_url)
    socket = WhisperGradioSocket(stream_transcript, base_url, sample_rate)
    socket.start()
    return socket
