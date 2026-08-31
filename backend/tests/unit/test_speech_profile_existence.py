"""Unit tests for the speech profile existence check (#5128).

/v3/speech-profile must report has_profile=true for ANY existing profile,
because the listen pipeline (routers/transcribe.py) uses the profile
regardless of age. A 90-day expiry applied only to this endpoint caused
users with older, actively-used profiles to be re-prompted to
"Teach Omi your voice" on every launch.
"""

import inspect
from pathlib import Path
from unittest.mock import MagicMock, patch

from utils.other import storage as storage_mod


class TestGetUserHasSpeechProfile:
    def _bucket_with_blob(self, exists: bool):
        blob = MagicMock()
        blob.exists.return_value = exists
        bucket = MagicMock()
        bucket.blob.return_value = blob
        return bucket, blob

    def test_existing_profile_counts_regardless_of_age(self):
        """An existing profile is reported as present — no age cutoff (#5128)."""
        bucket, blob = self._bucket_with_blob(exists=True)
        with patch.object(storage_mod, "_get_speech_profiles_bucket", return_value=bucket):
            assert storage_mod.get_user_has_speech_profile("uid1") is True
        # No metadata fetch for age checks — the old expiry code called blob.reload()
        blob.reload.assert_not_called()

    def test_missing_profile(self):
        bucket, _ = self._bucket_with_blob(exists=False)
        with patch.object(storage_mod, "_get_speech_profiles_bucket", return_value=bucket):
            assert storage_mod.get_user_has_speech_profile("uid1") is False

    def test_missing_bucket(self):
        with patch.object(storage_mod, "_get_speech_profiles_bucket", return_value=None):
            assert storage_mod.get_user_has_speech_profile("uid1") is False

    def test_local_storage_upload_and_read(self, monkeypatch, tmp_path):
        source = tmp_path / 'source.wav'
        source.write_bytes(b'profile audio')
        storage_dir = tmp_path / 'profiles'
        monkeypatch.setenv('SPEECH_PROFILE_LOCAL_STORAGE_DIR', str(storage_dir))

        url = storage_mod.upload_profile_audio(str(source), '../external-uid')

        assert url == '/v4/speech-profile/audio'
        assert storage_mod.get_user_has_speech_profile('../external-uid') is True
        stored_path = storage_mod.get_profile_audio_if_exists('../external-uid')
        assert stored_path is not None
        assert Path(stored_path).read_bytes() == b'profile audio'
        assert Path(stored_path).is_relative_to(storage_dir)

    def test_local_storage_missing_profile(self, monkeypatch, tmp_path):
        monkeypatch.setenv('SPEECH_PROFILE_LOCAL_STORAGE_DIR', str(tmp_path / 'profiles'))

        assert storage_mod.get_user_has_speech_profile('missing-uid') is False
        assert storage_mod.get_profile_audio_if_exists('missing-uid') is None

    def test_no_age_parameter_in_signature(self):
        """Guard against reintroducing an expiry knob on the existence check."""
        params = inspect.signature(storage_mod.get_user_has_speech_profile).parameters
        assert list(params) == ["uid"]

    def test_endpoint_does_not_pass_age_cutoff(self):
        """The /v3/speech-profile router must not filter profiles by age (#5128)."""
        router_src = Path(storage_mod.__file__).parents[2] / "routers" / "speech_profile.py"
        assert "max_age_days" not in router_src.read_text(encoding="utf-8")
