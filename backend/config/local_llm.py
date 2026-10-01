"""Pure runtime contract for a self-hosted OpenAI-compatible LLM endpoint.

Personal deployments without OpenAI/Gemini/OpenRouter keys can point every
ChatOpenAI-routable feature at one OpenAI-compatible server (Ollama, LM Studio,
vLLM, llama.cpp) instead:

    LLM_BASE_URL=http://127.0.0.1:11434/v1   # required
    LLM_MODEL_OVERRIDE=qwen3.6:latest        # required
    LLM_MODEL_OVERRIDE_LIGHT=...             # optional, for the nano-tier features
    LLM_API_KEY=...                          # optional; local servers ignore it
    LLM_REASONING_EFFORT=none                # optional; sent as reasoning_effort

The override is active only when both required values are set. Env is read at
the call boundary so tests and restarts see the current value.
"""

from __future__ import annotations

from dataclasses import dataclass
from os import environ as process_environ
from typing import Mapping, Optional

LOCAL_LLM_PROVIDER = 'local'
# Providers whose ChatOpenAI-shaped routes the override may replace. Anthropic
# (agentic chat) and Perplexity (web search) use provider-specific clients.
OVERRIDABLE_PROVIDERS = frozenset({'openai', 'gemini', 'openrouter'})
# Nano-tier models; routed to LLM_MODEL_OVERRIDE_LIGHT when it is set.
LIGHT_MODELS = frozenset({'gpt-5-nano', 'gemini-2.5-flash-lite'})
PLACEHOLDER_API_KEY = 'local-llm'


@dataclass(frozen=True)
class LocalLLMSettings:
    base_url: str
    model: str
    light_model: str
    api_key: str
    reasoning_effort: Optional[str]

    def model_for(self, upstream_model: str) -> str:
        return self.light_model if upstream_model in LIGHT_MODELS else self.model


def local_llm_settings(environ: Mapping[str, str] | None = None) -> Optional[LocalLLMSettings]:
    env = process_environ if environ is None else environ
    base_url = (env.get('LLM_BASE_URL') or '').strip().rstrip('/')
    model = (env.get('LLM_MODEL_OVERRIDE') or '').strip()
    if not base_url or not model:
        return None
    return LocalLLMSettings(
        base_url=base_url,
        model=model,
        light_model=(env.get('LLM_MODEL_OVERRIDE_LIGHT') or '').strip() or model,
        api_key=(env.get('LLM_API_KEY') or '').strip() or PLACEHOLDER_API_KEY,
        reasoning_effort=(env.get('LLM_REASONING_EFFORT') or '').strip() or None,
    )
