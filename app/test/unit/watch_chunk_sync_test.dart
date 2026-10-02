import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:omi/backend/http/api/conversations.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/services/watch_chunks/watch_chunk_codec.dart';
import 'package:omi/services/watch_chunks/watch_chunk_sync.dart';

import 'watch_chunk_codec_test.dart' show wavBytes;

WatchChunk chunk(int startedAtMs) => WatchChunk(
      chunkId: 'omiwatch_$startedAtMs',
      audioPath: '/inbox/omiwatch_$startedAtMs.wav',
      metaPath: '/inbox/omiwatch_$startedAtMs.json',
      startedAtMs: startedAtMs,
      durationMs: 30000,
    );

class FakeStore implements WatchChunkStore {
  FakeStore(Iterable<WatchChunk> chunks) : chunks = [...chunks];

  final List<WatchChunk> chunks;
  final List<String> deleted = [];
  final List<String> quarantined = [];
  final Set<String> unreadable = {};
  final List<List<String>> built = [];

  @override
  Future<List<WatchChunk>> list() async => [...chunks]..sort((a, b) => a.startedAtMs.compareTo(b.startedAtMs));

  @override
  Future<File> buildUploadFile(WatchChunk c) async {
    if (unreadable.contains(c.chunkId)) throw const FormatException('bad wav');
    built.add([c.chunkId]);
    return File('${Directory.systemTemp.path}/${WatchChunkCodec.uploadFileName(startedAtMs: c.startedAtMs)}');
  }

  @override
  Future<void> delete(WatchChunk c) async {
    chunks.removeWhere((x) => x.chunkId == c.chunkId);
    deleted.add(c.chunkId);
  }

  @override
  Future<void> quarantine(WatchChunk c) async {
    chunks.removeWhere((x) => x.chunkId == c.chunkId);
    quarantined.add(c.chunkId);
  }

  @override
  Future<List<String>> requeueQuarantined({Duration maxAge = const Duration(days: 3)}) async => const [];
}

class MemoryLedger implements WatchChunkLedger {
  final Set<String> done = {};
  final Map<String, String> jobs = {};
  final Map<String, int> failureCounts = {};

  @override
  bool isDone(String chunkId) => done.contains(chunkId);
  @override
  Future<void> markDone(Iterable<String> chunkIds) async => done.addAll(chunkIds);
  @override
  String? jobFor(String chunkId) => jobs[chunkId];
  @override
  Future<void> setJob(Iterable<String> chunkIds, String jobId) async {
    for (final id in chunkIds) {
      jobs[id] = jobId;
    }
  }

  @override
  Future<void> clearJob(Iterable<String> chunkIds) async => chunkIds.forEach(jobs.remove);
  @override
  int failures(String chunkId) => failureCounts[chunkId] ?? 0;
  @override
  Future<void> recordFailure(Iterable<String> chunkIds) async {
    for (final id in chunkIds) {
      failureCounts[id] = (failureCounts[id] ?? 0) + 1;
    }
  }

  @override
  Future<void> forget(Iterable<String> chunkIds) async {
    for (final id in chunkIds) {
      done.remove(id);
      jobs.remove(id);
      failureCounts.remove(id);
    }
  }
}

SyncJobFetch jobStatus(String status) => SyncJobFetch(
      SyncJobFetchOutcome.ok,
      SyncJobStatusResponse(jobId: 'job', status: status),
    );

void main() {
  late FakeStore store;
  late MemoryLedger ledger;
  late List<List<String>> uploads;
  late List<List<String>> acks;
  late List<Object Function()> uploadScript;
  late List<SyncJobFetch Function()> jobScript;

  WatchChunkSyncQueue makeQueue({int maxBatchChunks = 10, int maxAttempts = 12}) => WatchChunkSyncQueue(
        store: store,
        ledger: ledger,
        maxBatchChunks: maxBatchChunks,
        maxAttempts: maxAttempts,
        sleep: (_) async {},
        uploader: (files) async {
          uploads.add(files.map((f) => f.uri.pathSegments.last).toList());
          final next =
              uploadScript.isEmpty ? UploadFilesResult.queued('job-${uploads.length}') : uploadScript.removeAt(0)();
          if (next is UploadFilesResult) return next;
          throw next;
        },
        fetchJob: (jobId) async => jobScript.isEmpty ? jobStatus('completed') : jobScript.removeAt(0)(),
        ack: (ids) async {
          acks.add(ids);
          return true;
        },
      );

  setUp(() {
    store = FakeStore([chunk(3000), chunk(1000), chunk(2000)]);
    ledger = MemoryLedger();
    uploads = [];
    acks = [];
    uploadScript = [];
    jobScript = [];
  });

  test('uploads oldest-first as one batch, acks and deletes only after the job completes', () async {
    jobScript = [() => jobStatus('processing'), () => jobStatus('completed')];
    final result = await makeQueue().drain();

    expect(uploads, [
      [
        'audio_applewatch_pcm16_16000_1_fs320_1000.bin',
        'audio_applewatch_pcm16_16000_1_fs320_2000.bin',
        'audio_applewatch_pcm16_16000_1_fs320_3000.bin',
      ],
    ]);
    expect(acks, [
      ['omiwatch_1000', 'omiwatch_2000', 'omiwatch_3000'],
    ]);
    expect(store.deleted, ['omiwatch_1000', 'omiwatch_2000', 'omiwatch_3000']);
    expect(result.stop, WatchChunkDrainStop.idle);
    expect(result.uploaded, 3);
    expect(ledger.jobs, isEmpty);
  });

  test('respects the batch size and keeps chronological order across batches', () async {
    await makeQueue(maxBatchChunks: 2).drain();
    expect(uploads.map((u) => u.length).toList(), [2, 1]);
    expect(acks.expand((a) => a).toList(), ['omiwatch_1000', 'omiwatch_2000', 'omiwatch_3000']);
  });

  test('synchronous 200 fast-path with failed segments is not acked', () async {
    uploadScript = [
      () => UploadFilesResult.done(
            SyncLocalFilesResponse(newConversationIds: [], updatedConversationIds: [], failedSegments: 1),
          ),
    ];
    final result = await makeQueue().drain();
    expect(result.stop, WatchChunkDrainStop.retryLater);
    expect(acks, isEmpty);
    expect(store.deleted, isEmpty);
  });

  test('synchronous 200 fast-path counts as transcribed', () async {
    uploadScript = [
      () => UploadFilesResult.done(SyncLocalFilesResponse(newConversationIds: ['c1'], updatedConversationIds: []))
    ];
    await makeQueue().drain();
    expect(acks.single.length, 3);
  });

  test('network errors never ack, never delete, and never count toward quarantine', () async {
    uploadScript = [() => const SocketException('offline')];
    final queue = makeQueue(maxAttempts: 1);
    final result = await queue.drain();

    expect(result.stop, WatchChunkDrainStop.retryLater);
    expect(result.retryAfter, const Duration(seconds: 30));
    expect(acks, isEmpty);
    expect(store.deleted, isEmpty);
    expect(store.quarantined, isEmpty);
    expect(ledger.failureCounts, isEmpty);

    uploadScript = [() => Exception('Server is temporarily unavailable')];
    final second = await queue.drain();
    expect(second.retryAfter, const Duration(seconds: 60)); // backoff grows
    expect(store.quarantined, isEmpty);
  });

  test('rate limiting honors Retry-After', () async {
    uploadScript = [() => SyncRateLimitedException(kind: SyncRateLimitKind.backendCapacity, retryAfterSeconds: 30)];
    final result = await makeQueue().drain();
    expect(result.stop, WatchChunkDrainStop.retryLater);
    expect(result.retryAfter, const Duration(seconds: 30));
    expect(acks, isEmpty);
  });

  test('a still-processing job is resumed by polling, not re-uploaded', () async {
    final queue = WatchChunkSyncQueue(
      store: store,
      ledger: ledger,
      sleep: (_) async {},
      pollBudget: Duration.zero,
      uploader: (files) async {
        uploads.add(files.map((f) => f.path).toList());
        return UploadFilesResult.queued('job-1');
      },
      fetchJob: (jobId) async => jobScript.isEmpty ? jobStatus('completed') : jobScript.removeAt(0)(),
      ack: (ids) async {
        acks.add(ids);
        return true;
      },
    );
    jobScript = [() => jobStatus('processing')];
    final first = await queue.drain();
    expect(first.stop, WatchChunkDrainStop.retryLater);
    expect(ledger.jobFor('omiwatch_1000'), 'job-1');
    expect(acks, isEmpty);

    final second = await queue.drain();
    expect(second.stop, WatchChunkDrainStop.idle);
    expect(uploads.length, 1, reason: 'the in-flight job must be polled, not uploaded again');
    expect(acks.single, ['omiwatch_1000', 'omiwatch_2000', 'omiwatch_3000']);
  });

  test('an expired job id is re-uploaded on the next pass', () async {
    jobScript = [() => const SyncJobFetch(SyncJobFetchOutcome.notFound)];
    final queue = makeQueue();
    final first = await queue.drain();
    expect(first.stop, WatchChunkDrainStop.retryLater);
    expect(ledger.jobs, isEmpty);

    await queue.drain();
    expect(uploads.length, 2);
    expect(acks.single.length, 3);
  });

  test('a failed batch is retried oldest-chunk-alone, then the rest follow', () async {
    jobScript = [() => jobStatus('failed')];
    final queue = makeQueue();
    final first = await queue.drain();
    expect(first.stop, WatchChunkDrainStop.retryLater);
    expect(ledger.failures('omiwatch_1000'), 1);

    await queue.drain();
    expect(uploads[1], ['audio_applewatch_pcm16_16000_1_fs320_1000.bin']);
    expect(uploads[2].length, 2);
    expect(acks.expand((a) => a).toList(), ['omiwatch_1000', 'omiwatch_2000', 'omiwatch_3000']);
  });

  test('a poison chunk is quarantined after maxAttempts definitive failures and acked', () async {
    store = FakeStore([chunk(1000)]);
    jobScript = List.generate(3, (_) => () => jobStatus('failed'));
    final queue = makeQueue(maxAttempts: 3);
    for (var i = 0; i < 2; i++) {
      final r = await queue.drain();
      expect(r.stop, WatchChunkDrainStop.retryLater);
      expect(store.quarantined, isEmpty);
    }
    final last = await queue.drain();
    expect(last.quarantined, 1);
    expect(store.quarantined, ['omiwatch_1000']);
    expect(acks, [
      ['omiwatch_1000'],
    ]);
    expect(ledger.isDone('omiwatch_1000'), isTrue);
  });

  test('unreadable audio is quarantined immediately without blocking later chunks', () async {
    store.unreadable.add('omiwatch_2000');
    final queue = makeQueue();
    final first = await queue.drain(); // batch hits the bad file → split
    expect(first.stop, WatchChunkDrainStop.retryLater);
    expect(ledger.failures('omiwatch_2000'), 1);
    final second = await queue.drain(); // 1000 alone, then 2000 alone → quarantined, then 3000
    expect(second.stop, WatchChunkDrainStop.idle);
    expect(store.quarantined, ['omiwatch_2000']);
    expect(acks.expand((a) => a).toSet(), {'omiwatch_1000', 'omiwatch_2000', 'omiwatch_3000'});
    expect(store.chunks, isEmpty);
  });

  test('re-delivered duplicates of finished chunks are re-acked and deleted without upload', () async {
    await ledger.markDone(['omiwatch_1000', 'omiwatch_2000', 'omiwatch_3000']);
    final result = await makeQueue().drain();
    expect(uploads, isEmpty);
    expect(acks.single.toSet(), {'omiwatch_1000', 'omiwatch_2000', 'omiwatch_3000'});
    expect(store.chunks, isEmpty);
    expect(result.acknowledged, 3);
  });

  test('drain is single-flight', () async {
    final queue = makeQueue();
    final results = await Future.wait([queue.drain(), queue.drain()]);
    expect(results.map((r) => r.stop), containsAll([WatchChunkDrainStop.busy, WatchChunkDrainStop.idle]));
    expect(uploads.length, 1);
  });

  test('definitive upload rejections are distinguished from transient errors', () {
    expect(WatchChunkSyncQueue.isDefinitiveUploadRejection(Exception('Audio file could not be processed by server')),
        isTrue);
    expect(WatchChunkSyncQueue.isDefinitiveUploadRejection(Exception('Audio file is too large to upload')), isTrue);
    expect(WatchChunkSyncQueue.isDefinitiveUploadRejection(Exception('Server is temporarily unavailable')), isFalse);
    expect(WatchChunkSyncQueue.isDefinitiveUploadRejection(const SocketException('x')), isFalse);
    expect(WatchChunkSyncQueue.backoffFor(1), const Duration(seconds: 30));
    expect(WatchChunkSyncQueue.backoffFor(20), const Duration(minutes: 30));
  });

  group('FileWatchChunkStore', () {
    late Directory dir;
    late Directory temp;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('watch_inbox');
      temp = await Directory.systemTemp.createTemp('watch_tmp');
    });

    tearDown(() async {
      await dir.delete(recursive: true);
      await temp.delete(recursive: true);
    });

    Future<void> writeChunk(int startedAtMs, {bool withAudio = true}) async {
      final id = 'omiwatch_$startedAtMs';
      if (withAudio) await File('${dir.path}/$id.wav').writeAsBytes(wavBytes(Uint8List(32000)));
      await File('${dir.path}/$id.json').writeAsString(jsonEncode({
        'kind': 'omiWatchChunk',
        'chunkId': id,
        'startedAtMs': startedAtMs,
        'durationMs': 1000,
        'sampleRate': 16000,
        'channels': 1,
      }));
    }

    test('lists committed chunks oldest-first, builds sync .bin uploads, quarantines and requeues', () async {
      await writeChunk(1759370002000);
      await writeChunk(1759370001000);
      await writeChunk(1759370003000, withAudio: false); // sidecar without audio: not committed
      await File('${dir.path}/garbage.json').writeAsString('{not json');

      final fileStore = FileWatchChunkStore(dir.path, tempDirectory: () async => temp);
      final chunks = await fileStore.list();
      expect(chunks.map((c) => c.chunkId), ['omiwatch_1759370001000', 'omiwatch_1759370002000']);

      final upload = await fileStore.buildUploadFile(chunks.first);
      expect(upload.path, '${temp.path}/audio_applewatch_pcm16_16000_1_fs320_1759370001000.bin');
      expect(await upload.length(), 32000 + 4 * 50); // 50 frames of 640 bytes, 4-byte prefix each

      await fileStore.quarantine(chunks.first);
      expect((await fileStore.list()).length, 1);
      expect(await File('${dir.path}/failed/omiwatch_1759370001000.wav').exists(), isTrue);

      final requeued = await fileStore.requeueQuarantined();
      expect(requeued, ['omiwatch_1759370001000']);
      expect((await fileStore.list()).length, 2);

      await fileStore.delete(chunks.last);
      expect((await fileStore.list()).map((c) => c.chunkId), ['omiwatch_1759370001000']);
    });
  });
}
