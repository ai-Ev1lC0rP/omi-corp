import 'dart:typed_data';

/// Apple Watch store-and-forward chunk formats.
///
/// The watch writes PCM16 / 16 kHz / mono WAV chunks. `/v2/sync-local-files` accepts the
/// length-prefixed `.bin` container the Omi device sync already uses: repeated
/// `[uint32 little-endian frame length][frame bytes]`, with codec, sample rate, frame size and
/// capture time encoded in the filename (`_pcm16_<rate>_<channels>_fs<frame>_<unix ms>.bin`).
class WatchChunkCodec {
  /// Filename device marker; the backend maps `applewatch` to the `apple_watch` source.
  static const String deviceMarker = 'applewatch';

  /// 20 ms of PCM16 at 16 kHz.
  static const int frameSamples = 320;

  /// Backend-compatible upload filename for a chunk that started at [startedAtMs].
  static String uploadFileName({required int startedAtMs, int sampleRate = 16000, int channels = 1}) {
    return 'audio_${deviceMarker}_pcm16_${sampleRate}_${channels}_fs${frameSamples}_$startedAtMs.bin';
  }

  /// Extracts the PCM payload and format from a RIFF/WAVE file. Throws [FormatException]
  /// for anything that is not uncompressed 16-bit PCM.
  static WavPcm parseWav(Uint8List wav) {
    if (wav.length < 12 || _ascii(wav, 0, 4) != 'RIFF' || _ascii(wav, 8, 4) != 'WAVE') {
      throw const FormatException('not a RIFF/WAVE file');
    }
    final data = ByteData.sublistView(wav);
    int? sampleRate;
    int? channels;
    var offset = 12;
    while (offset + 8 <= wav.length) {
      final id = _ascii(wav, offset, 4);
      final size = data.getUint32(offset + 4, Endian.little);
      final body = offset + 8;
      if (id == 'fmt ') {
        if (body + 16 > wav.length) throw const FormatException('truncated fmt chunk');
        final audioFormat = data.getUint16(body, Endian.little);
        channels = data.getUint16(body + 2, Endian.little);
        sampleRate = data.getUint32(body + 4, Endian.little);
        final bits = data.getUint16(body + 14, Endian.little);
        if (audioFormat != 1 || bits != 16) {
          throw FormatException('unsupported WAV encoding format=$audioFormat bits=$bits');
        }
      } else if (id == 'data') {
        if (sampleRate == null || channels == null) throw const FormatException('data chunk before fmt chunk');
        // A writer killed mid-chunk can leave size 0/short; trust the bytes actually present.
        var end = (size == 0 || body + size > wav.length) ? wav.length : body + size;
        final blockAlign = 2 * channels;
        end -= (end - body) % blockAlign;
        return WavPcm(pcm: Uint8List.sublistView(wav, body, end), sampleRate: sampleRate, channels: channels);
      }
      offset = body + size + (size.isOdd ? 1 : 0);
    }
    throw const FormatException('no data chunk');
  }

  /// Wraps raw PCM16 into the sync `.bin` container, [frameSamples] samples per frame.
  static Uint8List pcmToSyncBin(Uint8List pcm, {int channels = 1}) {
    final frameBytes = frameSamples * 2 * channels;
    final frames = (pcm.length + frameBytes - 1) ~/ frameBytes;
    final out = BytesBuilder(copy: false);
    final header = ByteData(4);
    for (var i = 0; i < frames; i++) {
      final start = i * frameBytes;
      final end = (start + frameBytes) > pcm.length ? pcm.length : start + frameBytes;
      final length = end - start;
      if (length <= 0) break;
      header.setUint32(0, length, Endian.little);
      out.add(Uint8List.fromList(header.buffer.asUint8List()));
      out.add(Uint8List.sublistView(pcm, start, end));
    }
    return out.takeBytes();
  }

  static String _ascii(Uint8List bytes, int offset, int length) {
    if (offset + length > bytes.length) return '';
    return String.fromCharCodes(bytes.sublist(offset, offset + length));
  }
}

class WavPcm {
  final Uint8List pcm;
  final int sampleRate;
  final int channels;

  const WavPcm({required this.pcm, required this.sampleRate, required this.channels});

  int get durationMs => sampleRate <= 0 ? 0 : pcm.length * 1000 ~/ (sampleRate * 2 * channels);
}
