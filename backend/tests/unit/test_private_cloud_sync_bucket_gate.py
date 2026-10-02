"""New listen conversations only enable private cloud sync when a bucket is configured.

``utils.other.storage`` defaults the bucket name to the hosted service's bucket, which a
self-hosted service account cannot list: finalization logged a 403 for every conversation.
Without an explicit BUCKET_PRIVATE_CLOUD_SYNC the conversation is created without cloud audio,
so the audio-file step is skipped instead of failing.
"""

from routers.listen.conversations import conversation_private_cloud_sync_enabled


def test_requires_user_setting_and_explicit_bucket(monkeypatch):
    monkeypatch.delenv('BUCKET_PRIVATE_CLOUD_SYNC', raising=False)
    assert conversation_private_cloud_sync_enabled(True) is False
    monkeypatch.setenv('BUCKET_PRIVATE_CLOUD_SYNC', '  ')
    assert conversation_private_cloud_sync_enabled(True) is False
    monkeypatch.setenv('BUCKET_PRIVATE_CLOUD_SYNC', 'my-private-cloud-sync')
    assert conversation_private_cloud_sync_enabled(True) is True
    assert conversation_private_cloud_sync_enabled(False) is False
