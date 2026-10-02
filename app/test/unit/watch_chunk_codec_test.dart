import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:omi/services/watch_chunks/watch_chunk_codec.dart';
import 'package:omi/utils/batch_recording.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';

Uint8List wavBytes(Uint8List pcm, {int sampleRate = 16000, int channels = 1, int? dataSizeOverride}) {
  final header = ByteData(44);
  void ascii(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      header.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  final dataSize = dataSizeOverride ?? pcm.length;
  ascii(0, 'RIFF');
  header.setUint32(4, 36 + dataSize, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, channels, Endian.little);
  header.setUint32(24, sampleRate, Endian.little);
  header.setUint32(28, sampleRate * channels * 2, Endian.little);
  header.setUint16(32, channels * 2, Endian.little);
  header.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  header.setUint32(40, dataSize, Endian.little);
  return Uint8List.fromList([...header.buffer.asUint8List(), ...pcm]);
}

void main() {
  group('WatchChunkCodec.uploadFileName', () {
    test('matches the backend sync filename contract and the shared batch parser', () {
      final name = WatchChunkCodec.uploadFileName(startedAtMs: 1759370000123);
      expect(name, 'audio_applewatch_pcm16_16000_1_fs320_1759370000123.bin');

      final info = BatchRecordingInfo.fromFileName(name);
      expect(info, isNotNull);
      expect(info!.codec, BleAudioCodec.pcm16);
      expect(info.frameSize, 320);
      expect(info.sampleRate, 16000);
      expect(info.timerStart, 1759370000); // ms are normalized to seconds
    });
  });

  group('WatchChunkCodec.parseWav', () {
    test('extracts PCM and format', () {
      final pcm = Uint8List.fromList(List.generate(64000, (i) => i % 256)); // 2 s
      final parsed = WatchChunkCodec.parseWav(wavBytes(pcm));
      expect(parsed.sampleRate, 16000);
      expect(parsed.channels, 1);
      expect(parsed.pcm, pcm);
      expect(parsed.durationMs, 2000);
    });

    test('recovers audio when a killed writer left a zero data size', () {
      final pcm = Uint8List.fromList(List.filled(3201, 7)); // odd byte trimmed to whole samples
      final parsed = WatchChunkCodec.parseWav(wavBytes(pcm, dataSizeOverride: 0));
      expect(parsed.pcm.length, 3200);
    });

    test('rejects non-WAV and compressed input', () {
      expect(() => WatchChunkCodec.parseWav(Uint8List.fromList([1, 2, 3])), throwsFormatException);
      final wav = wavBytes(Uint8List(10));
      ByteData.sublistView(wav).setUint16(20, 3, Endian.little); // IEEE float
      expect(() => WatchChunkCodec.parseWav(wav), throwsFormatException);
    });
  });

  group('WatchChunkCodec.pcmToSyncBin', () {
    test('frames PCM as little-endian length-prefixed 320-sample frames', () {
      final pcm = Uint8List.fromList(List.generate(640 * 2 + 100, (i) => i % 251));
      final bin = WatchChunkCodec.pcmToSyncBin(pcm);
      final view = ByteData.sublistView(bin);

      final lengths = <int>[];
      final payload = <int>[];
      var offset = 0;
      while (offset < bin.length) {
        final length = view.getUint32(offset, Endian.little);
        lengths.add(length);
        payload.addAll(bin.sublist(offset + 4, offset + 4 + length));
        offset += 4 + length;
      }
      expect(lengths, [640, 640, 100]);
      expect(payload, pcm);
      expect(lengths.every((l) => l % 2 == 0), isTrue);
    });

    test('empty PCM produces an empty container', () {
      expect(WatchChunkCodec.pcmToSyncBin(Uint8List(0)), isEmpty);
    });
  });
}
