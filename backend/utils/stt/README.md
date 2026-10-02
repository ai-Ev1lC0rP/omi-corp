# `utils/stt` — speech-to-text providers and audio gates

Package map for the backend's transcription code. Live sessions (`/v4/listen`) pick a
streaming provider in `streaming.py`; pre-recorded and sync audio go through `pre_recorded.py`.

| Module | Role |
| --- | --- |
| `socket.py` | `STTSocket`, the minimal interface every live provider socket implements. |
| `streaming.py` | Live provider selection (`STTService`, `get_stt_service_for_language`) and the Deepgram / Modulate / Parakeet socket clients with connect fallback. |
| `safe_socket.py` | `SafeDeepgramSocket`: keepalive and dead-connection detection around a Deepgram socket. |
| `provider_resilience.py` | Process-local circuit breaker that stops repeated connects to an unhealthy provider. |
| `live_failure.py` | Terminal handling when a live provider fails to start or dies mid-session. |
| `whisper_gradio.py` | Live provider for a self-hosted Whisper-WebUI (Gradio) server, selected when `WHISPER_GRADIO_URL` is set: energy segmentation into utterances, the positional `transcribe_file` parameters, and the upload/call/SSE flow. |
| `whisper_guards.py` | Hallucination guards for `whisper_gradio`: `SpeechGate` (loudness + WebRTC VAD + YIN periodicity) before upload, `filter_transcript` (known hallucination phrases, repetition loops, prompt echoes) after. |
| `vad.py` | Silero VAD (`assets/silero_vad.onnx`) helpers for emptiness checks on audio windows. |
| `vad_gate.py` | Optional streaming VAD gate (`VAD_GATE_MODE=shadow|active`) that wraps a live socket and withholds silence. |
| `pre_recorded.py` | Pre-recorded transcription providers (Deepgram, Modulate, fal WhisperX). |
| `outcomes.py` | Privacy-safe outcome/failure classification for pre-recorded transcription. |
| `speaker_embedding.py` | Speaker embedding extraction and comparison. |
| `speech_profile.py` | Speech-profile matching against a user's stored samples. |

Live provider sockets must never block the listen receive loop: `send` is synchronous and cheap,
and network work runs in a background task (see `WhisperGradioSocket`).
