"""Stale in_progress recovery stops retrying rows it can never finalize.

Every listen session runs ``recover_stale_in_progress``. A row whose transcript blob cannot be
decrypted (its key is gone), or an empty row that survives deletion, used to be retried by every
session forever: hundreds of attempts and ~1,400 ERROR lines a day for one user. Now each pass
is counted on the row and, after ``STALE_IN_PROGRESS_RECOVERY_MAX_ATTEMPTS``, the row is moved
to ``failed`` + discarded (status fields only; the encrypted data is untouched).
"""

import json
import zlib
from types import SimpleNamespace

import pytest

from database import conversations as conversations_db
from database import stale_conversation_recovery as stale_recovery_db
from routers.listen import conversations as listen_conversations
from utils.conversations import lifecycle as lifecycle_service
from routers.listen.conversations import STALE_IN_PROGRESS_RECOVERY_MAX_ATTEMPTS, LiveConversationController


class _Host:
    def __init__(self, stale, rows_after_processing=None, current_conversation_id=None):
        self.request = SimpleNamespace(uid='uid-1')
        self.state = SimpleNamespace(current_conversation_id=current_conversation_id)
        self.stale = stale
        self.rows_after_processing = rows_after_processing or {}
        self.calls: list[tuple] = []
        self.persistence = SimpleNamespace(call=self._call)

    async def wait(self, _seconds):
        return False

    async def _call(self, fn, *args, **kwargs):
        name = fn.__name__
        self.calls.append((name, *args))
        if name == 'get_stale_in_progress_conversations':
            return self.stale
        if name == 'get_processing_conversations':
            return []
        if name == 'classify_raw_conversation_content':
            return fn(*args, **kwargs)
        if name == 'get_conversation':
            return self.rows_after_processing.get(args[1])
        if name in ('record_stale_recovery_attempt', 'mark_stale_conversation_terminal'):
            return True
        raise AssertionError(f'unexpected persistence call {name}')

    def named(self, name):
        return [call[1:] for call in self.calls if call[0] == name]


class _Controller(LiveConversationController):
    def __init__(self, host):
        super().__init__(host)
        self.processed: list[str] = []

    async def process_conversation(self, conversation_id: str) -> bool:
        self.processed.append(conversation_id)
        return True


@pytest.fixture
def lost_key(monkeypatch):
    # encryption.decrypt returns its input when the key does not match.
    monkeypatch.setattr(conversations_db.encryption, 'decrypt', lambda data, _uid: data)


def _undecryptable(cid, attempts=None):
    row = {'id': cid, 'transcript_segments': 'bm90LWhleA==', 'transcript_segments_compressed': True}
    if attempts is not None:
        row['recovery_attempts'] = attempts
    return row


async def test_undecryptable_row_is_counted_not_processed(lost_key):
    host = _Host([_undecryptable('conv-lost')])
    controller = _Controller(host)

    await controller.recover_stale_in_progress()

    assert controller.processed == []  # finalization cannot read it either
    assert host.named('record_stale_recovery_attempt') == [('uid-1', 'conv-lost', 1)]
    assert host.named('mark_stale_conversation_terminal') == []


async def test_undecryptable_row_becomes_terminal_on_the_last_attempt(lost_key):
    host = _Host([_undecryptable('conv-lost', attempts=STALE_IN_PROGRESS_RECOVERY_MAX_ATTEMPTS - 1)])
    controller = _Controller(host)

    await controller.recover_stale_in_progress()

    assert controller.processed == []
    assert host.named('mark_stale_conversation_terminal') == [
        ('uid-1', 'conv-lost', 'undecryptable', STALE_IN_PROGRESS_RECOVERY_MAX_ATTEMPTS)
    ]
    assert host.named('record_stale_recovery_attempt') == []


async def test_empty_row_that_is_deleted_needs_no_bookkeeping():
    host = _Host([{'id': 'conv-empty', 'transcript_segments': []}])
    controller = _Controller(host)

    await controller.recover_stale_in_progress()

    assert controller.processed == ['conv-empty']
    assert host.named('record_stale_recovery_attempt') == []


async def test_empty_row_that_survives_is_terminal_after_max_attempts():
    survivor = {'id': 'conv-empty', 'status': 'in_progress', 'transcript_segments': []}
    host = _Host([{'id': 'conv-empty', 'transcript_segments': []}], {'conv-empty': survivor})
    controller = _Controller(host)
    await controller.recover_stale_in_progress()
    assert host.named('record_stale_recovery_attempt') == [('uid-1', 'conv-empty', 1)]

    host = _Host(
        [{'id': 'conv-empty', 'transcript_segments': [], 'recovery_attempts': 2}],
        {'conv-empty': survivor},
    )
    controller = _Controller(host)
    await controller.recover_stale_in_progress()
    assert host.named('mark_stale_conversation_terminal') == [('uid-1', 'conv-empty', 'empty', 3)]


async def test_readable_content_still_goes_to_finalization_without_a_cap():
    row = {'id': 'conv-real', 'transcript_segments': [{'text': 'hello'}], 'recovery_attempts': 9}
    host = _Host([row])
    controller = _Controller(host)

    await controller.recover_stale_in_progress()

    assert controller.processed == ['conv-real']
    assert host.named('record_stale_recovery_attempt') == []
    assert host.named('mark_stale_conversation_terminal') == []


async def test_current_conversation_is_never_touched(lost_key):
    host = _Host([_undecryptable('conv-live', attempts=5)], current_conversation_id='conv-live')
    controller = _Controller(host)

    await controller.recover_stale_in_progress()

    assert host.named('mark_stale_conversation_terminal') == []
    assert host.named('classify_raw_conversation_content') == []


def test_classify_raw_conversation_content(lost_key):
    classify = stale_recovery_db.classify_raw_conversation_content
    assert classify('u', {}) == 'empty'
    assert classify('u', {'transcript_segments': []}) == 'empty'
    assert classify('u', {'transcript_segments': [{'text': 'hi'}]}) == 'content'
    assert classify('u', {'photos': [{'id': 'p'}]}) == 'content'
    assert classify('u', {'has_content': True}) == 'content'
    empty_blob = zlib.compress(json.dumps([]).encode())
    assert classify('u', {'transcript_segments': empty_blob, 'transcript_segments_compressed': True}) == 'empty'
    full_blob = zlib.compress(json.dumps([{'text': 'hi'}]).encode())
    assert classify('u', {'transcript_segments': full_blob, 'transcript_segments_compressed': True}) == 'content'
    assert classify('u', _undecryptable('x')) == 'undecodable'
    # Undecodable stays undecodable even when has_content says otherwise: it cannot be finalized.
    assert classify('u', {**_undecryptable('x'), 'has_content': True}) == 'undecodable'
    assert classify('u', {'transcript_segments': 'garbage', 'transcript_segments_compressed': False}) == 'undecodable'


def test_mark_terminal_is_a_conditional_status_only_transition(monkeypatch):
    captured = {}

    def fake_claim(uid, conversation_id, expected, claimed, extra_updates=None):
        captured.update(uid=uid, cid=conversation_id, expected=expected, claimed=claimed, extra=extra_updates)
        return True

    monkeypatch.setattr(conversations_db, 'claim_conversation_status', fake_claim)
    assert lifecycle_service.mark_stale_conversation_terminal('u', 'c', 'undecryptable', 3) is True
    assert captured['expected'].value == 'in_progress' and captured['claimed'].value == 'failed'
    extra = captured['extra']
    assert extra['discarded'] is True and extra['recovery_terminal_reason'] == 'undecryptable'
    assert extra['recovery_attempts'] == 3
    assert not {'transcript_segments', 'transcript_segments_compressed'} & set(extra)


def test_max_attempts_is_small_but_more_than_one():
    assert 1 < listen_conversations.STALE_IN_PROGRESS_RECOVERY_MAX_ATTEMPTS <= 5
