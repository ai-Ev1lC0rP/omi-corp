"""Self-hosted LLM override, in-process listen finalization and vector-less processing."""

import asyncio
import json
import struct
from types import SimpleNamespace

import pytest

import utils.conversations.process_conversation as pc
import utils.pusher_finalization as pusher_finalization
from config.local_llm import PLACEHOLDER_API_KEY, local_llm_settings
from utils import listen_inprocess_finalization as inprocess
from utils.llm import model_config, providers

_LOCAL_ENV = ('LLM_BASE_URL', 'LLM_MODEL_OVERRIDE', 'LLM_MODEL_OVERRIDE_LIGHT', 'LLM_API_KEY', 'LLM_REASONING_EFFORT')


@pytest.fixture
def local_env(monkeypatch):
    for name in _LOCAL_ENV:
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv('LLM_BASE_URL', 'http://127.0.0.1:11434/v1/')
    monkeypatch.setenv('LLM_MODEL_OVERRIDE', 'qwen3.6:latest')
    return monkeypatch


def test_settings_require_base_url_and_model():
    assert local_llm_settings({}) is None
    assert local_llm_settings({'LLM_BASE_URL': 'http://x/v1'}) is None
    assert local_llm_settings({'LLM_MODEL_OVERRIDE': 'm'}) is None

    settings = local_llm_settings({'LLM_BASE_URL': 'http://x/v1/', 'LLM_MODEL_OVERRIDE': 'big'})
    assert settings is not None
    assert settings.base_url == 'http://x/v1'
    assert settings.api_key == PLACEHOLDER_API_KEY
    assert settings.reasoning_effort is None
    assert settings.model_for('gpt-5-nano') == 'big'  # light falls back to the main model

    settings = local_llm_settings(
        {'LLM_BASE_URL': 'http://x/v1', 'LLM_MODEL_OVERRIDE': 'big', 'LLM_MODEL_OVERRIDE_LIGHT': 'small'}
    )
    assert settings is not None
    assert settings.model_for('gpt-5-nano') == 'small'
    assert settings.model_for('gemini-2.5-flash-lite') == 'small'
    assert settings.model_for('gpt-5.6-luna') == 'big'


def test_routes_unchanged_without_override(monkeypatch):
    for name in _LOCAL_ENV:
        monkeypatch.delenv(name, raising=False)
    assert model_config.get_model_config('conv_structure') == ('gpt-5.6-luna', 'openai')
    assert model_config.get_provider('session_titles') == 'gemini'


def test_override_reroutes_chat_openai_features_only(local_env):
    local_env.setenv('LLM_MODEL_OVERRIDE_LIGHT', 'qwen3:8b')
    assert model_config.get_model_config('conv_structure') == ('qwen3.6:latest', 'local')
    assert model_config.get_model_config('conv_discard') == ('qwen3:8b', 'local')
    assert model_config.get_model_config('session_titles') == ('qwen3:8b', 'local')
    assert model_config.get_model_config('wrapped_analysis') == ('qwen3.6:latest', 'local')
    assert model_config.get_model_config('fair_use')[1] == 'local'
    # Provider-specific clients keep their routes.
    assert model_config.get_model_config('chat_agent') == ('claude-sonnet-4-6', 'anthropic')
    assert model_config.get_model_config('web_search') == ('sonar-pro', 'perplexity')


def test_route_options_carry_reasoning_effort(local_env):
    assert model_config.get_route_options('conv_structure', 'qwen3.6:latest', 'local') == {}
    local_env.setenv('LLM_REASONING_EFFORT', 'none')
    assert model_config.get_route_options('conv_structure', 'qwen3.6:latest', 'local') == {
        'extra_body': {'reasoning_effort': 'none'}
    }


def test_local_provider_builds_chat_openai_against_endpoint(local_env):
    built = {}

    class FakeChatOpenAI:
        def __init__(self, **kwargs):
            built.update(kwargs)

    local_env.setattr(providers, 'ChatOpenAI', FakeChatOpenAI)
    providers._llm_cache.clear()
    try:
        providers.get_or_create_openai_compatible_llm('local', 'qwen3.6:latest', options={})
    finally:
        providers._llm_cache.clear()
    assert built['model'] == 'qwen3.6:latest'
    assert built['base_url'] == 'http://127.0.0.1:11434/v1'
    assert built['api_key'].get_secret_value() == PLACEHOLDER_API_KEY


def test_inprocess_flag(monkeypatch):
    monkeypatch.delenv('LISTEN_INPROCESS_FINALIZATION', raising=False)
    assert not inprocess.is_inprocess_finalization_enabled()
    monkeypatch.setenv('LISTEN_INPROCESS_FINALIZATION', 'true')
    assert inprocess.is_inprocess_finalization_enabled()


def _result_frame(result):
    return struct.pack('I', 201) + json.dumps(result).encode('utf-8')


def test_inprocess_processor_runs_leased_worker_and_reports_success(monkeypatch):
    calls = []

    async def fake_task(uid, conversation_id, language, websocket, byok_keys, job_id, generation):
        calls.append((uid, conversation_id, language, byok_keys, job_id, generation))
        await websocket.send_bytes(_result_frame({'conversation_id': conversation_id, 'success': True}))

    monkeypatch.setattr(pusher_finalization, 'process_conversation_task', fake_task)
    processed = []
    request = inprocess.make_inprocess_conversation_processor('uid-1', 'en', lambda: {}, processed.append)

    async def run():
        assert await request('conv-1', 'job-1', 2) is True
        await asyncio.sleep(0)
        await asyncio.sleep(0)

    asyncio.run(run())
    assert calls == [('uid-1', 'conv-1', 'en', None, 'job-1', 2)]
    assert processed == ['conv-1']


def test_inprocess_result_sink_ignores_errors():
    processed = []
    sink = inprocess._ResultSink(processed.append)
    asyncio.run(
        sink.send_bytes(_result_frame({'conversation_id': 'c', 'error': 'processing_failed', 'terminal': True}))
    )
    asyncio.run(sink.send_bytes(_result_frame({'conversation_id': 'c', 'fenced': True})))
    assert processed == []


def test_save_structured_vector_skips_without_vector_db(monkeypatch):
    monkeypatch.setattr(pc.vector_db, 'index', None)

    def fail(*_args, **_kwargs):
        raise AssertionError('must not embed or upsert without a vector DB')

    monkeypatch.setattr(pc, 'generate_embedding', fail)
    monkeypatch.setattr(pc, 'upsert_vector2', fail)
    monkeypatch.setattr(pc, 'retrieve_metadata_fields_from_transcript', fail)
    pc.save_structured_vector('uid-1', SimpleNamespace(id='conv-1'))
