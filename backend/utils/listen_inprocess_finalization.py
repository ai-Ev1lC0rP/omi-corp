"""In-process listen finalization for deployments that run no pusher service.

Without ``HOSTED_PUSHER_API_URL`` the listen session has no route for a durable
finalization job, so every conversation stayed queued and was never summarized.
Setting ``LISTEN_INPROCESS_FINALIZATION=true`` (personal single-process
deployments) runs the same leased pusher worker, ``process_conversation_task``,
inside this process instead. The Firestore job lease, attempt budget and
dead-lettering are unchanged; only the transport is local.
"""

from __future__ import annotations

import json
import logging
import os
from typing import Any, Callable, Dict, Optional

from utils.executors import start_background_task

logger = logging.getLogger(__name__)

_RESULT_HEADER_BYTES = 4


def is_inprocess_finalization_enabled() -> bool:
    return os.getenv('LISTEN_INPROCESS_FINALIZATION', '').strip().lower() in {'1', 'true', 'yes'}


class _ResultSink:
    """Stands in for the pusher socket: decodes the 201 result frame locally."""

    def __init__(self, on_success: Callable[[str], None]):
        self._on_success = on_success

    async def send_bytes(self, data: bytes) -> None:
        result = json.loads(data[_RESULT_HEADER_BYTES:].decode('utf-8'))
        conversation_id = result.get('conversation_id')
        if result.get('success') and conversation_id:
            self._on_success(conversation_id)
        elif 'error' in result:
            logger.warning(
                'in-process finalization failed conversation=%s error=%s terminal=%s',
                conversation_id,
                result.get('error'),
                bool(result.get('terminal')),
            )


def make_inprocess_conversation_processor(
    uid: str,
    language: str,
    get_byok_keys: Callable[[], Dict[str, Any]],
    on_conversation_processed: Callable[[str], None],
):
    """Return a drop-in for ``ListenPusherSession.request_conversation_processing``."""

    async def request_conversation_processing(
        conversation_id: str,
        finalization_job_id: Optional[str] = None,
        dispatch_generation: Optional[int] = None,
    ) -> bool:
        from utils.pusher_finalization import process_conversation_task

        # Process scope, like pusher: finalization must survive the listen socket closing.
        start_background_task(
            process_conversation_task(
                uid,
                conversation_id,
                language,
                _ResultSink(on_conversation_processed),  # type: ignore[arg-type]
                get_byok_keys() or None,
                finalization_job_id,
                dispatch_generation,
            ),
            name=f'inprocess_finalization:{uid}:{conversation_id}',
        )
        logger.info('in-process finalization started conversation=%s uid=%s', conversation_id, uid)
        return True

    return request_conversation_processing
