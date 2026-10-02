"""Bookkeeping for stale ``in_progress`` recovery (#9809) on rows that can never finalize.

Every listen session retries orphaned ``in_progress`` conversations. A row whose transcript blob
cannot be decoded (for example, encrypted under a lost key), or an empty row that cannot be
deleted, used to be retried by every session forever. These helpers classify such rows, count
attempts on the row; the terminal status transition itself lives in the lifecycle service
(``utils.conversations.lifecycle.mark_stale_conversation_terminal``). They live beside
``database.conversations`` (mirroring its strict decoder) rather than in it, to keep that module
from growing.
"""

from __future__ import annotations

import json
import zlib
from datetime import datetime, timezone
from typing import Any, Dict, List

from google.api_core.exceptions import NotFound

from database import conversations as conversations_db
from utils import encryption


def _decode_segments(uid: str, raw_segments: Any, compressed: bool) -> List[Any]:
    """Decode a stored ``transcript_segments`` blob the way the write path encoded it; raise if unreadable."""
    if isinstance(raw_segments, list):
        return raw_segments
    if isinstance(raw_segments, str):
        payload = encryption.decrypt(raw_segments, uid)  # returns its input when the key does not match
        if compressed:
            return json.loads(zlib.decompress(bytes.fromhex(payload)).decode('utf-8'))
        return json.loads(payload)
    if isinstance(raw_segments, bytes) and compressed:
        return json.loads(zlib.decompress(raw_segments).decode('utf-8'))
    raise ValueError(f'undecodable transcript_segments: {type(raw_segments).__name__} compressed={compressed}')


def classify_raw_conversation_content(uid: str, conversation: Dict[str, Any]) -> str:
    """Classify an un-decoded snapshot as ``'content'``, ``'empty'`` or ``'undecodable'``.

    Unlike ``raw_conversation_has_content``, an unreadable blob is reported as such instead of
    being assumed to be content, so recovery can stop retrying it. Nothing is logged here
    besides the decryptor's own line.
    """
    if conversation.get('photos'):
        return 'content'
    raw_segments = conversation.get('transcript_segments')
    if not raw_segments:
        return 'content' if conversation.get('has_content') else 'empty'
    try:
        segments = _decode_segments(uid, raw_segments, bool(conversation.get('transcript_segments_compressed')))
    except (json.JSONDecodeError, TypeError, UnicodeDecodeError, zlib.error, ValueError):
        return 'undecodable'
    if segments or conversation.get('has_content'):
        return 'content'
    return 'empty'


def _conversation_ref(uid: str, conversation_id: str):
    return (
        conversations_db.db.collection('users')
        .document(uid)
        .collection(conversations_db.conversations_collection)
        .document(conversation_id)
    )


def record_stale_recovery_attempt(uid: str, conversation_id: str, attempts: int) -> bool:
    """Persist the stale-recovery attempt count on the conversation. False if it is gone."""
    try:
        _conversation_ref(uid, conversation_id).update(
            {'recovery_attempts': attempts, 'recovery_last_attempt_at': datetime.now(timezone.utc)}
        )
    except NotFound:
        return False
    return True
