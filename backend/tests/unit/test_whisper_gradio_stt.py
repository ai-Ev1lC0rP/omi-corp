"""Self-hosted Whisper-WebUI (Gradio) live STT: SSE parsing, WAV/chunk building, socket flow."""

import asyncio
import io
import json
import wave

import httpx
import numpy as np
import pytest

from config.stt_provider_policy import STTServingSurface
from utils.stt import streaming
from utils.transcribe_decisions import client_codec_for_source
from utils.stt.whisper_gradio import (
    TRANSCRIBE_PARAMS,
    UtteranceSegmenter,
    WhisperGradioError,
    WhisperGradioSocket,
    build_transcribe_payload,
    clean_result_text,
    extract_transcript,
    parse_sse_events,
    parse_upload_response,
    pcm16_to_wav,
    transcribe_wav,
    whisper_gradio_live_selection,
    whisper_gradio_url,
)

SR = 16000


def _tone(seconds: float, amp: int = 6000) -> bytes:
    t = np.arange(int(SR * seconds)) / SR
    return (amp * np.sin(2 * np.pi * 220 * t)).astype('<i2').tobytes()


def _silence(seconds: float) -> bytes:
    return b'\x00\x00' * int(SR * seconds)


# ---------------------------------------------------------------- SSE parsing


def test_extract_transcript_strips_done_header_and_banner():
    raw = 'Done in 2.9 seconds! Subtitle is in the outputs folder.\n\n------------------------------------\nomi-chunk\n\nHello there.\nSecond line.\n'
    body = 'event: generating\ndata: null\n\nevent: complete\ndata: ' + json.dumps([raw, ['/tmp/x.txt']]) + '\n\n'
    assert extract_transcript(body) == 'Hello there. Second line.'


def test_extract_transcript_crlf_and_multiline_data():
    body = 'event: complete\r\ndata: ["Done in 1 seconds!\\nhi",\r\ndata: null]\r\n\r\n'
    assert parse_sse_events(body) == [('complete', '["Done in 1 seconds!\\nhi",\nnull]')]
    assert extract_transcript(body) == 'hi'


def test_extract_transcript_error_event_raises():
    with pytest.raises(WhisperGradioError, match='event: error'):
        extract_transcript('event: error\ndata: null\n\n')
    with pytest.raises(WhisperGradioError, match='CUDA OOM'):
        extract_transcript('event: error\ndata: "CUDA OOM"\n\n')


def test_extract_transcript_missing_complete_and_bad_json():
    with pytest.raises(WhisperGradioError, match='no "event: complete"'):
        extract_transcript('event: heartbeat\ndata: null\n\n')
    with pytest.raises(WhisperGradioError, match='not JSON'):
        extract_transcript('event: complete\ndata: {oops\n\n')


def test_clean_result_text_empty_and_plain():
    assert clean_result_text('Done in 0.4 seconds!\n') == ''
    assert clean_result_text('  just text  ') == 'just text'


def test_upload_response_and_payload_shape():
    assert parse_upload_response(['/tmp/gradio/abc/omi-chunk.wav']) == '/tmp/gradio/abc/omi-chunk.wav'
    with pytest.raises(WhisperGradioError):
        parse_upload_response({'detail': 'nope'})
    payload = build_transcribe_payload('/srv/a.wav')
    assert payload['data'][0] == [{'path': '/srv/a.wav', 'meta': {'_type': 'gradio.FileData'}}]
    assert len(payload['data']) == 1 + 53 and len(TRANSCRIBE_PARAMS) == 53
    assert payload['data'][1 + 5] == 'large-v3-turbo' and payload['data'][1 + 6] == 'english'
    assert payload['data'][1 + 3] == 'txt' and payload['data'][1 + 45] == ''  # never ship an HF token


# ---------------------------------------------------------------- WAV + chunking


def test_pcm16_to_wav_roundtrip():
    pcm = _tone(0.5)
    with wave.open(io.BytesIO(pcm16_to_wav(pcm, SR))) as w:
        assert (w.getnchannels(), w.getsampwidth(), w.getframerate()) == (1, 2, SR)
        assert w.readframes(w.getnframes()) == pcm


def test_segmenter_splits_on_silence_with_session_offsets():
    seg = UtteranceSegmenter(SR, silence_s=0.6)
    out = []
    audio = _silence(1.0) + _tone(1.5) + _silence(1.0) + _tone(2.0) + _silence(1.0)
    for i in range(0, len(audio), 3200):  # 100 ms frames like the app
        out += seg.push(audio[i : i + 3200])
    out += seg.flush()
    assert len(out) == 2
    assert out[0].start == pytest.approx(0.7, abs=0.06)  # 1.0 s minus 0.3 s pre-roll
    assert out[0].duration == pytest.approx(1.5 + 0.3 + 0.2, abs=0.1)
    assert out[1].start == pytest.approx(3.5 - 0.3, abs=0.06)
    assert all(len(u.pcm) % 2 == 0 for u in out)


def test_segmenter_splits_long_speech_at_quietest_point_without_losing_audio():
    seg = UtteranceSegmenter(SR, max_s=5.0, split_search_s=2.0)
    # Continuous speech with a brief soft dip (a word gap shorter than silence_s) at 4.2 s.
    audio = _tone(4.2) + _tone(0.09, amp=900) + _tone(7.71)
    out = seg.push(audio)
    assert 4.2 <= out[0].duration <= 4.3  # cut inside the dip, not at 5.0 s
    out += seg.flush()
    assert out[1].start == pytest.approx(out[0].end, abs=1e-6)  # chunks are contiguous
    assert sum(len(u.pcm) for u in out) == len(audio)  # nothing lost across splits
    assert all(u.duration <= 5.0 + 1e-6 for u in out)


def test_segmenter_drops_noise_and_flushes_tail():
    seg = UtteranceSegmenter(SR)
    assert seg.push(_silence(3.0) + _tone(0.06) + _silence(2.0)) == []  # a click is not speech
    assert seg.flush() == []
    seg.push(_silence(1.0) + _tone(2.0))
    tail = seg.flush()  # socket close mid-utterance
    assert len(tail) == 1 and tail[0].start == pytest.approx(5.0 + 0.7, abs=0.06)  # offsets are session-relative


def test_segmenter_adapts_to_steady_loud_background():
    rng = np.random.default_rng(0)
    noise = (rng.normal(0, 1500, SR * 90)).astype('<i2').tobytes()  # 90 s of fan-like noise
    seg = UtteranceSegmenter(SR, max_s=12.0)
    out = seg.push(noise)
    # Early chunks may read as speech, but the floor catches up and the noise stops chunking.
    assert sum(u.duration for u in out) < 60
    assert seg.push(noise[: SR * 2 * 20]) == []


def test_apple_watch_pcm8_label_is_decoded_as_pcm16():
    assert client_codec_for_source('pcm8', 'apple_watch') == 'pcm16'
    assert client_codec_for_source('pcm16', 'apple_watch') == 'pcm16'
    assert client_codec_for_source('pcm8', 'omi') == 'pcm8'  # real 8-bit devices are untouched
    assert client_codec_for_source('pcm8', None) == 'pcm8'
    assert client_codec_for_source('opus', 'apple_watch') == 'opus'


# ---------------------------------------------------------------- HTTP flow + socket


def _gradio_transport(calls, text='Hello Omi.', fail_first=False):
    def handler(request: httpx.Request) -> httpx.Response:
        calls.append((request.method, request.url.path))
        if request.url.path == '/gradio_api/upload':
            if fail_first and len([c for c in calls if c[1] == '/gradio_api/upload']) == 1:
                return httpx.Response(500, text='boom')
            assert b'name="files"' in request.content
            return httpx.Response(200, json=['/tmp/gradio/x/omi-chunk.wav'])
        if request.url.path == '/gradio_api/call/transcribe_file':
            body = json.loads(request.content)
            assert body['data'][0][0]['path'] == '/tmp/gradio/x/omi-chunk.wav'
            return httpx.Response(200, json={'event_id': 'ev1'})
        if request.url.path == '/gradio_api/call/transcribe_file/ev1':
            data = json.dumps(['Done in 1.0 seconds!\n' + text, None])
            return httpx.Response(200, text=f'event: complete\ndata: {data}\n\n')
        return httpx.Response(404)

    return httpx.MockTransport(handler)


def test_transcribe_wav_three_calls():
    calls = []

    async def run():
        async with httpx.AsyncClient(transport=_gradio_transport(calls)) as client:
            return await transcribe_wav(client, 'http://whisper', pcm16_to_wav(_tone(0.5), SR))

    assert asyncio.run(run()) == 'Hello Omi.'
    assert [p for _, p in calls] == [
        '/gradio_api/upload',
        '/gradio_api/call/transcribe_file',
        '/gradio_api/call/transcribe_file/ev1',
    ]


def test_socket_emits_segments_and_survives_failed_chunk():
    calls, emitted = [], []

    async def run():
        client = httpx.AsyncClient(transport=_gradio_transport(calls, fail_first=True))
        sock = WhisperGradioSocket(emitted.extend, 'http://whisper/', SR, client=client)
        sock.start()
        audio = _tone(1.0) + _silence(1.0) + _tone(1.0) + _silence(0.2)
        for i in range(0, len(audio), 3200):
            assert sock.send(audio[i : i + 3200]) is True
            await asyncio.sleep(0)
        await sock.drain_and_close()
        await client.aclose()
        return sock

    sock = asyncio.run(run())
    assert (sock.chunks_failed, sock.chunks_ok) == (1, 1)
    assert not sock.is_connection_dead
    assert len(emitted) == 1
    s = emitted[0]
    assert s['text'] == 'Hello Omi.' and s['speaker'] == 'SPEAKER_00' and s['is_user'] is False
    assert s['start'] == pytest.approx(1.7, abs=0.06) and s['end'] > s['start']
    assert sock.send(b'\x00\x00') is False  # closed after drain


def test_live_selection_uses_whisper_gradio_only_when_configured(monkeypatch):
    monkeypatch.setenv('WHISPER_GRADIO_URL', 'http://100.78.123.116:8999/')
    assert whisper_gradio_live_selection('en-US') == (streaming.STTService.whisper_gradio, 'en', 'large-v3-turbo')
    assert whisper_gradio_live_selection(None) == (streaming.STTService.whisper_gradio, 'en', 'large-v3-turbo')
    assert whisper_gradio_url() == 'http://100.78.123.116:8999'
    # Push-to-talk and the policy-owned selection never return the live-only provider.
    ptt = streaming.get_stt_service_for_language('en', surface=STTServingSurface.PTT)
    assert ptt[0] != streaming.STTService.whisper_gradio
    assert streaming.get_stt_service_for_language('en')[0] != streaming.STTService.whisper_gradio
    monkeypatch.delenv('WHISPER_GRADIO_URL')
    assert whisper_gradio_live_selection('en') is None
