"""Offline Sync on a single-host deployment: VAD segments go to Whisper-WebUI from disk."""

import wave

import pytest

from utils.stt.pre_recorded import postprocess_words
from utils.stt.whisper_gradio import WHISPER_GRADIO_MODEL
from utils.sync import local_stt
from utils.sync.lanes import inline_backfill_enabled

# Fakes replace local_stt._transcribe (the httpx client + Whisper-WebUI round trip) so the
# fast-unit CPU budget is not spent building TLS contexts; transcribe_wav is covered by
# tests/unit/test_whisper_gradio_stt.py.


def _write_wav(path, seconds: float, rate: int = 16000):
    with wave.open(str(path), 'wb') as writer:
        writer.setnchannels(1)
        writer.setsampwidth(2)
        writer.setframerate(rate)
        writer.writeframes(b'\x00\x00' * int(rate * seconds))


def test_disabled_without_explicit_opt_in(monkeypatch):
    monkeypatch.setenv('WHISPER_GRADIO_URL', 'http://whisper:8999')
    monkeypatch.delenv('SYNC_PRERECORDED_STT', raising=False)
    assert local_stt.sync_local_stt_enabled() is False


def test_disabled_without_whisper_url(monkeypatch):
    monkeypatch.setenv('SYNC_PRERECORDED_STT', 'whisper_gradio')
    monkeypatch.delenv('WHISPER_GRADIO_URL', raising=False)
    assert local_stt.sync_local_stt_enabled() is False


def test_enabled_with_opt_in_and_url(monkeypatch):
    monkeypatch.setenv('SYNC_PRERECORDED_STT', 'Whisper_Gradio')
    monkeypatch.setenv('WHISPER_GRADIO_URL', 'http://whisper:8999/')
    assert local_stt.sync_local_stt_enabled() is True


def test_transcribe_segment_words_spans_segment(monkeypatch, tmp_path):
    monkeypatch.setenv('WHISPER_GRADIO_URL', 'http://whisper:8999')
    seen = {}

    async def fake_transcribe(base_url, wav, timeout):
        seen['base_url'] = base_url
        seen['riff'] = wav[:4]
        return '  hello from the watch  '

    monkeypatch.setattr(local_stt, '_transcribe', fake_transcribe)
    path = tmp_path / '1759370000.5.wav'
    _write_wav(path, 2.5)

    words = local_stt.transcribe_segment_words(str(path))

    assert seen == {'base_url': 'http://whisper:8999', 'riff': b'RIFF'}
    assert words == [{'timestamp': [0.0, 2.5], 'speaker': 'SPEAKER_00', 'text': 'hello from the watch'}]


def test_transcribe_segment_words_empty_text_is_no_speech(monkeypatch, tmp_path):
    monkeypatch.setenv('WHISPER_GRADIO_URL', 'http://whisper:8999')

    async def fake_transcribe(base_url, wav, timeout):
        return '   '

    monkeypatch.setattr(local_stt, '_transcribe', fake_transcribe)
    path = tmp_path / '1759370000.wav'
    _write_wav(path, 1.0)
    assert local_stt.transcribe_segment_words(str(path)) == []


def test_transcribe_segment_words_propagates_server_errors(monkeypatch, tmp_path):
    monkeypatch.setenv('WHISPER_GRADIO_URL', 'http://whisper:8999')

    async def fake_transcribe(base_url, wav, timeout):
        raise RuntimeError('whisper down')

    monkeypatch.setattr(local_stt, '_transcribe', fake_transcribe)
    path = tmp_path / '1759370000.wav'
    _write_wav(path, 1.0)
    with pytest.raises(RuntimeError, match='whisper down'):
        local_stt.transcribe_segment_words(str(path))


def test_words_survive_prerecorded_postprocessing(monkeypatch, tmp_path):
    """The single word group must produce a real TranscriptSegment through postprocess_words."""
    segments = postprocess_words(
        [{'timestamp': [0.0, 4.0], 'speaker': 'SPEAKER_00', 'text': 'testing the watch chunk'}], 0
    )
    assert len(segments) == 1
    assert segments[0].text == 'Testing the watch chunk'
    assert segments[0].start == 0 and segments[0].end == 4.0


def test_model_label_mirrors_live_whisper_gradio_model():
    assert local_stt.SYNC_LOCAL_STT_MODEL == WHISPER_GRADIO_MODEL


def test_service_triple_and_transcribe_segment_shape(monkeypatch, tmp_path):
    monkeypatch.delenv('SYNC_PRERECORDED_STT', raising=False)
    assert local_stt.service_triple() is None

    monkeypatch.setenv('SYNC_PRERECORDED_STT', 'whisper_gradio')
    monkeypatch.setenv('WHISPER_GRADIO_URL', 'http://whisper.local:8999')
    assert local_stt.service_triple() == ('whisper_gradio', None, local_stt.SYNC_LOCAL_STT_MODEL)

    path = tmp_path / 'seg.wav'
    _write_wav(path, seconds=1.0)

    async def fake_transcribe(base_url, wav, timeout):
        return 'hi'

    monkeypatch.setattr(local_stt, '_transcribe', fake_transcribe)
    words, language = local_stt.transcribe_segment(str(path))
    assert language == 'en'
    assert words[0]['text'] == 'hi'


def test_read_segment_bytes(tmp_path):
    path = tmp_path / 'seg.wav'
    path.write_bytes(b'RIFFdata')
    assert local_stt.read_segment_bytes(str(path)) == b'RIFFdata'
    assert local_stt.read_segment_bytes(str(tmp_path / 'missing.wav')) is None


def test_inline_backfill_flag_defaults_off(monkeypatch):
    monkeypatch.delenv('SYNC_INLINE_BACKFILL_ENABLED', raising=False)
    assert inline_backfill_enabled() is False
    monkeypatch.setenv('SYNC_INLINE_BACKFILL_ENABLED', 'true')
    assert inline_backfill_enabled() is True


def test_known_whisper_hallucination_is_dropped(monkeypatch, tmp_path):
    monkeypatch.setenv('WHISPER_GRADIO_URL', 'http://whisper:8999')

    async def fake_transcribe(base_url, wav, timeout):
        return 'Thank you.'

    monkeypatch.setattr(local_stt, '_transcribe', fake_transcribe)
    path = tmp_path / '1759370000.wav'
    _write_wav(path, 1.0)
    assert local_stt.transcribe_segment_words(str(path)) == []
