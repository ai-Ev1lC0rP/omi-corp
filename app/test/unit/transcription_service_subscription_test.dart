import 'package:flutter_test/flutter_test.dart';

import 'package:omi/backend/schema/message_event.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/backend/schema/transcript_segment.dart';
import 'package:omi/services/sockets/pure_socket.dart';
import 'package:omi/services/sockets/transcription_service.dart';

void main() {
  test('replays onboarding question received before listener subscribes', () {
    final service = TranscriptSegmentSocketService.withSocket(
      16000,
      BleAudioCodec.pcm16,
      'en',
      _FakePureSocket(),
      onboardingMode: true,
    );
    final listener = _RecordingListener();

    service.onMessage(
      '{"type":"onboarding_question","question":"How old are you?","question_index":0,"total_questions":6}',
    );
    service.subscribe(Object(), listener);

    expect(listener.events, hasLength(1));
    final event = listener.events.single as OnboardingQuestionEvent;
    expect(event.question, 'How old are you?');
    expect(event.questionIndex, 0);
    expect(event.totalQuestions, 6);
  });
}

class _RecordingListener implements ITransctiptSegmentSocketServiceListener {
  final List<MessageEvent> events = [];

  @override
  void onMessageEventReceived(MessageEvent event) => events.add(event);

  @override
  void onClosed([int? closeCode]) {}

  @override
  void onConnected() {}

  @override
  void onError(Object err) {}

  @override
  void onSegmentReceived(List<TranscriptSegment> segments) {}
}

class _FakePureSocket implements IPureSocket {
  IPureSocketListener? listener;

  @override
  PureSocketStatus get status => PureSocketStatus.connected;

  @override
  Future<bool> connect() async => true;

  @override
  Future<void> disconnect() async {}

  @override
  void onClosed() => listener?.onClosed();

  @override
  void onConnected() => listener?.onConnected();

  @override
  void onError(Object err, StackTrace trace) => listener?.onError(err, trace);

  @override
  void onMessage(dynamic message) => listener?.onMessage(message);

  @override
  void send(dynamic message) {}

  @override
  void setListener(IPureSocketListener listener) => this.listener = listener;

  @override
  Future<void> stop() async {}
}
