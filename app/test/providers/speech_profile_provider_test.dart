import 'package:flutter_test/flutter_test.dart';

import 'package:omi/backend/schema/transcript_segment.dart';
import 'package:omi/providers/speech_profile_provider.dart';

void main() {
  test('phone microphone onboarding ignores streaming speaker label changes', () {
    final provider = SpeechProfileProvider()..usePhoneMic = true;
    provider.segments.add(
      _segment(id: 'one', speaker: 'SPEAKER_0', text: 'I am thirty years old', start: 0, end: 1),
    );

    provider.onSegmentReceived([
      _segment(id: 'two', speaker: 'SPEAKER_1', text: 'I live in Iowa', start: 2, end: 3),
    ]);

    expect(provider.error, isNull);
    expect(provider.text, contains('I am thirty years old'));
    expect(provider.text, contains('I live in Iowa'));
  });
}

TranscriptSegment _segment({
  required String id,
  required String speaker,
  required String text,
  required double start,
  required double end,
}) {
  return TranscriptSegment(
    id: id,
    text: text,
    speaker: speaker,
    isUser: true,
    personId: null,
    start: start,
    end: end,
    translations: const [],
  );
}
