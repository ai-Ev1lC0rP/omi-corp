"""Whisper hallucination guards: the local speech gate and the transcript post-filter."""

import numpy as np
import pytest

from utils.stt.whisper_guards import (
    HALLUCINATION_PHRASES,
    SpeechGate,
    collapse_repeats,
    filter_transcript,
    normalize_text,
    yin_aperiodicity,
)

SR = 16000
_rng = np.random.default_rng(42)


def _pcm(x: np.ndarray) -> bytes:
    return np.clip(x, -32768, 32767).astype('<i2').tobytes()


def _pink(seconds: float, rms: float) -> bytes:
    n = int(SR * seconds)
    spectrum = np.fft.rfft(_rng.normal(size=n))
    freqs = np.fft.rfftfreq(n, 1 / SR)
    freqs[0] = 1.0
    x = np.fft.irfft(spectrum / np.sqrt(freqs), n)
    return _pcm(x / np.std(x) * rms)


def _brown(seconds: float, rms: float) -> bytes:
    x = np.cumsum(_rng.normal(size=int(SR * seconds)))
    x -= np.convolve(x, np.ones(800) / 800, 'same')
    return _pcm(x / np.std(x) * rms)


def _room_tone(seconds: float) -> bytes:
    n = int(SR * seconds)
    t = np.arange(n) / SR
    x = np.frombuffer(_pink(seconds, 350), '<i2').astype(np.float64) + 250 * np.sin(2 * np.pi * 60 * t)
    for start in _rng.integers(0, n - 100, 6):  # clicks / sleeve rustle
        x[start : start + 60] += _rng.normal(0, 6000, 60)
    return _pcm(x)


def _vowel(seconds: float, f0: float = 160.0, peak: float = 9000.0) -> bytes:
    """Glottal pulse train through three formant resonators, syllable-rate envelope: voiced speech."""
    n = int(SR * seconds)
    t = np.arange(n) / SR
    phase = np.cumsum(f0 * (1 + 0.05 * np.sin(2 * np.pi * 3 * t))) / SR
    y = (np.diff(np.floor(phase), prepend=0) > 0).astype(np.float64)
    for fc, bw in ((700, 130), (1220, 70), (2600, 160)):
        r, theta = np.exp(-np.pi * bw / SR), 2 * np.pi * fc / SR
        a1, a2 = -2 * r * np.cos(theta), r * r
        out = np.zeros(n)
        for i in range(n):
            out[i] = y[i] - a1 * (out[i - 1] if i else 0.0) - a2 * (out[i - 2] if i > 1 else 0.0)
        y = out
    y *= 0.6 + 0.4 * np.sin(2 * np.pi * 4 * t)
    return _pcm(y / np.max(np.abs(y)) * peak)


# ---------------------------------------------------------------- speech gate


@pytest.mark.parametrize(
    'name,pcm',
    [
        ('pink', _pink(3.0, 800)),
        ('loud pink', _pink(4.0, 2500)),
        ('white', _pcm(_rng.normal(0, 1500, SR * 3))),
        ('brown rumble', _brown(3.0, 2000)),
        ('room tone', _room_tone(6.0)),
        ('near silence', _pcm(_rng.normal(0, 25, SR * 5))),
        ('digital silence', b'\x00\x00' * SR * 2),
    ],
)
@pytest.mark.parametrize('use_webrtc', [True, False])
def test_gate_drops_noise_and_silence(name, pcm, use_webrtc):
    result = SpeechGate(use_webrtc=use_webrtc).evaluate(pcm, SR)
    assert not result.passed, (name, result)
    assert result.voiced_s < 0.1, (name, result)


@pytest.mark.parametrize('use_webrtc', [True, False])
def test_gate_passes_voiced_speech(use_webrtc):
    pcm = _pcm(np.zeros(SR // 2)) + _vowel(1.5) + _pcm(np.zeros(SR // 2))
    result = SpeechGate(use_webrtc=use_webrtc).evaluate(pcm, SR)
    assert result.passed, result
    assert result.voiced_s >= 1.0


def test_gate_requires_minimum_speech_duration():
    gate = SpeechGate(use_webrtc=False, min_speech_s=0.6)
    assert not gate.evaluate(_vowel(0.4), SR).passed  # a blip of voice is not an utterance
    assert gate.evaluate(_vowel(0.9), SR).passed


def test_gate_handles_empty_and_odd_length_audio():
    gate = SpeechGate()
    assert not gate.evaluate(b'', SR).passed
    assert not gate.evaluate(b'\x01', SR).passed
    assert gate.evaluate(_vowel(1.0) + b'\x01', SR).frames > 0


def test_yin_separates_periodic_from_noise():
    frame = int(SR * 0.03)
    t = np.arange(frame) / SR
    periodic = np.stack([np.sign(np.sin(2 * np.pi * 150 * t)) * 5000]).astype(np.float32)
    noise = _rng.normal(0, 5000, (1, frame)).astype(np.float32)
    assert yin_aperiodicity(periodic, SR)[0] < 0.2
    assert yin_aperiodicity(noise, SR)[0] > 0.5


# ---------------------------------------------------------------- transcript filter


@pytest.mark.parametrize(
    'text',
    [
        'Thank you.',
        'You',
        ' you ',
        'Thanks for watching!',
        'Thank you for watching.',
        'Bye.',
        'Subscribe',
        "I'm so excited to be here.",
        "I'll see you next time.",
        '.',
        '...',
        '♪',
        '♪♪ ♪',
        '[Music]',
        '(applause)',
        'Thank you. Thank you. Thank you.',
        'Thank you. Bye.',
        'you you you you you you',
        'Subtitles by the Amara.org community',
        'I went to the store. I went to the store. I went to the store. I went to the store.',
    ],
)
def test_filter_drops_hallucinations(text):
    kept, reason = filter_transcript(text)
    assert kept == '' and reason, text


@pytest.mark.parametrize(
    'text',
    [
        'Thank you for the coffee.',
        'Hi, this is Cason testing the backend.',
        'Okay, sounds good.',
        'So I think we should go.',
        'Bye, see you at five tomorrow.',
        'Yes, yes, I know, I will call you back.',
    ],
)
def test_filter_keeps_real_speech_unchanged(text):
    assert filter_transcript(text) == (text, None)


def test_filter_drops_echo_of_the_initial_prompt_only():
    prompt = 'Notes from Cason Clark.'
    assert filter_transcript('Cason Clark.', prompt=prompt) == ('', 'prompt_echo')
    assert filter_transcript('Notes from Cason Clark', prompt=prompt) == ('', 'prompt_echo')
    assert filter_transcript('Cason Clark here, calling about Friday.', prompt=prompt)[1] is None
    assert filter_transcript('Cason Clark.')[1] is None  # no prompt, no echo rule


def test_normalize_and_collapse_helpers():
    assert normalize_text("  I’m SO excited — to be here!! ") == 'im so excited to be here'
    assert normalize_text('♪ ♪') == ''
    assert collapse_repeats('thank you thank you thank you'.split()) == ['thank', 'you']
    assert collapse_repeats('a b a b'.split()) == ['a', 'b', 'a', 'b']  # two repeats are not a loop
    assert all(p == normalize_text(p) for p in HALLUCINATION_PHRASES)
