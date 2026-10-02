import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:omi/backend/http/api/conversations.dart';
import 'package:omi/services/watch_chunks/watch_chunk_codec.dart';
import 'package:omi/services/wals/sync_upload_gate.dart';
import 'package:omi/utils/logger.dart';

/// One Apple Watch audio chunk persisted on the phone by the native WatchChunkInbox.
class WatchChunk {
  final String chunkId;
  final String audioPath;
  final String metaPath;
  final int startedAtMs;
  final int durationMs;
  final int sampleRate;
  final int channels;

  const WatchChunk({
    required this.chunkId,
    required this.audioPath,
    required this.metaPath,
    required this.startedAtMs,
    required this.durationMs,
    this.sampleRate = 16000,
    this.channels = 1,
  });

  /// Parses the JSON sidecar the native inbox writes next to `<chunkId>.wav`.
  static WatchChunk? fromSidecar(Map<String, dynamic> json, {required String directory}) {
    final chunkId = json['chunkId'];
    final startedAtMs = json['startedAtMs'];
    if (chunkId is! String || chunkId.isEmpty || startedAtMs is! num || startedAtMs <= 0) return null;
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(chunkId)) return null;
    return WatchChunk(
      chunkId: chunkId,
      audioPath: '$directory/$chunkId.wav',
      metaPath: '$directory/$chunkId.json',
      startedAtMs: startedAtMs.toInt(),
      durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
      sampleRate: (json['sampleRate'] as num?)?.toInt() ?? 16000,
      channels: (json['channels'] as num?)?.toInt() ?? 1,
    );
  }
}

/// Filesystem side of the queue (injectable for tests).
abstract class WatchChunkStore {
  /// Committed chunks (sidecar + audio both present), oldest first.
  Future<List<WatchChunk>> list();

  /// Builds the `/v2/sync-local-files` upload file for [chunk]; caller deletes it.
  Future<File> buildUploadFile(WatchChunk chunk);

  Future<void> delete(WatchChunk chunk);

  /// Keep an unprocessable chunk for inspection instead of retrying it forever.
  Future<void> quarantine(WatchChunk chunk);

  /// Move recent quarantined chunks back into the queue; returns their ids.
  Future<List<String>> requeueQuarantined({Duration maxAge = const Duration(days: 3)});
}

/// Durable bookkeeping: completed chunk ids (to re-ack duplicates), in-flight sync jobs,
/// and per-chunk failure counts.
abstract class WatchChunkLedger {
  bool isDone(String chunkId);
  Future<void> markDone(Iterable<String> chunkIds);
  String? jobFor(String chunkId);
  Future<void> setJob(Iterable<String> chunkIds, String jobId);
  Future<void> clearJob(Iterable<String> chunkIds);
  int failures(String chunkId);
  Future<void> recordFailure(Iterable<String> chunkIds);

  /// Forget everything about [chunkIds] (used when quarantined chunks are re-queued).
  Future<void> forget(Iterable<String> chunkIds);
}

typedef WatchChunkUploader = Future<UploadFilesResult> Function(List<File> files);
typedef WatchChunkJobFetcher = Future<SyncJobFetch> Function(String jobId);
typedef WatchChunkAcker = Future<bool> Function(List<String> chunkIds);

enum WatchChunkDrainStop { idle, retryLater, busy }

class WatchChunkDrainResult {
  final int uploaded;
  final int acknowledged;
  final int quarantined;
  final WatchChunkDrainStop stop;
  final Duration? retryAfter;

  const WatchChunkDrainResult({
    required this.uploaded,
    required this.acknowledged,
    required this.quarantined,
    required this.stop,
    this.retryAfter,
  });
}

/// In-order, single-flight upload queue for watch chunks.
///
/// Chunks are uploaded oldest-first through the existing offline-sync endpoint in batches of
/// consecutive chunks (one sync job each, so the backend merges them into conversations by
/// their filename timestamps and re-summarizes once per batch). Only after the job reports
/// `completed` are the chunks acknowledged to the watch and deleted on the phone. A
/// transient failure stops the drain so ordering is preserved; the caller retries after
/// [WatchChunkDrainResult.retryAfter].
class WatchChunkSyncQueue {
  WatchChunkSyncQueue({
    required this.store,
    required this.ledger,
    required this.uploader,
    required this.fetchJob,
    required this.ack,
    this.maxBatchChunks = 10,
    this.maxAttempts = 12,
    this.pollInterval = const Duration(seconds: 3),
    this.pollBudget = const Duration(minutes: 10),
    Future<void> Function(Duration)? sleep,
  }) : _sleep = sleep ?? ((d) => Future<void>.delayed(d));

  final WatchChunkStore store;
  final WatchChunkLedger ledger;
  final WatchChunkUploader uploader;
  final WatchChunkJobFetcher fetchJob;
  final WatchChunkAcker ack;
  final int maxBatchChunks;
  final int maxAttempts;
  final Duration pollInterval;
  final Duration pollBudget;
  final Future<void> Function(Duration) _sleep;

  bool _draining = false;
  int _transientStreak = 0;

  bool get isDraining => _draining;

  /// Exponential backoff 30 s → 30 min by consecutive failure count.
  @visibleForTesting
  static Duration backoffFor(int failures) {
    final seconds = 30 * math.pow(2, math.max(0, failures - 1)).toInt();
    return Duration(seconds: math.min(seconds, 30 * 60));
  }

  Future<WatchChunkDrainResult> drain() async {
    if (_draining) {
      return const WatchChunkDrainResult(uploaded: 0, acknowledged: 0, quarantined: 0, stop: WatchChunkDrainStop.busy);
    }
    _draining = true;
    var uploaded = 0;
    var acknowledged = 0;
    var quarantined = 0;
    try {
      while (true) {
        final chunks = await store.list();

        // Duplicates of chunks we already finished: re-ack so the watch can delete them.
        final done = chunks.where((c) => ledger.isDone(c.chunkId)).toList();
        if (done.isNotEmpty) {
          await ack(done.map((c) => c.chunkId).toList());
          for (final chunk in done) {
            await store.delete(chunk);
          }
          acknowledged += done.length;
        }

        final pending = chunks.where((c) => !ledger.isDone(c.chunkId)).toList();
        if (pending.isEmpty) {
          return WatchChunkDrainResult(
            uploaded: uploaded,
            acknowledged: acknowledged,
            quarantined: quarantined,
            stop: WatchChunkDrainStop.idle,
          );
        }

        final batch = _nextBatch(pending);
        final outcome = await _process(batch);
        switch (outcome.kind) {
          case _OutcomeKind.success:
            final ids = batch.map((c) => c.chunkId).toList();
            await ledger.markDone(ids);
            await ledger.clearJob(ids);
            await ack(ids);
            for (final chunk in batch) {
              await store.delete(chunk);
            }
            uploaded += batch.length;
            acknowledged += batch.length;
            _transientStreak = 0;
            Logger.debug('[WatchChunks] synced ${ids.length} chunk(s) ${ids.first}..${ids.last}');
          case _OutcomeKind.permanent:
            // Only ever a single chunk: batches that fail are split before giving up.
            final ids = batch.map((c) => c.chunkId).toList();
            Logger.warning('[WatchChunks] giving up on ${ids.join(",")}: ${outcome.reason}');
            for (final chunk in batch) {
              await store.quarantine(chunk);
            }
            await ledger.markDone(ids);
            await ledger.clearJob(ids);
            await ack(ids);
            quarantined += batch.length;
          case _OutcomeKind.retry:
            return WatchChunkDrainResult(
              uploaded: uploaded,
              acknowledged: acknowledged,
              quarantined: quarantined,
              stop: WatchChunkDrainStop.retryLater,
              retryAfter: outcome.retryAfter,
            );
        }
      }
    } finally {
      _draining = false;
    }
  }

  /// Oldest pending chunk plus the consecutive chunks that share its in-flight job (if
  /// any), or that are not yet failing. A chunk with prior failures is retried alone so a
  /// poison chunk cannot hold good audio hostage.
  List<WatchChunk> _nextBatch(List<WatchChunk> pending) {
    final first = pending.first;
    final firstJob = ledger.jobFor(first.chunkId);
    if (firstJob != null) {
      return pending.where((c) => ledger.jobFor(c.chunkId) == firstJob).toList();
    }
    if (ledger.failures(first.chunkId) > 0) return [first];
    final batch = <WatchChunk>[];
    for (final chunk in pending) {
      if (batch.length >= maxBatchChunks) break;
      if (ledger.jobFor(chunk.chunkId) != null || ledger.failures(chunk.chunkId) > 0) break;
      batch.add(chunk);
    }
    return batch;
  }

  Future<_Outcome> _process(List<WatchChunk> batch) async {
    final ids = batch.map((c) => c.chunkId).toList();
    var jobId = ledger.jobFor(ids.first);
    if (jobId == null) {
      final files = <File>[];
      var building = batch.first;
      try {
        for (final chunk in batch) {
          building = chunk;
          files.add(await store.buildUploadFile(chunk));
        }
        final result = await uploader(files);
        if (!result.isQueued) {
          final failedSegments = result.completed?.failedSegments ?? 0;
          if (failedSegments > 0) return _failed(batch, 'sync reported $failedSegments failed segment(s)');
          return const _Outcome.success();
        }
        jobId = result.jobId!;
        await ledger.setJob(ids, jobId);
      } on SyncRateLimitedException catch (e) {
        return _Outcome.retry(Duration(seconds: e.retryAfterSeconds ?? 60), 'rate limited');
      } on SyncRecoveryWindowExceededException {
        if (batch.length == 1) return const _Outcome.permanent('older than the recovery window');
        await ledger.recordFailure([ids.first]);
        return const _Outcome.retry(Duration.zero, 'split batch');
      } on FormatException catch (e) {
        // The audio itself is unreadable; retrying cannot help. Mark the offending chunk so
        // the next batch stops before it and it is then retried alone (and quarantined).
        if (batch.length == 1) return _Outcome.permanent('unreadable audio: ${e.message}');
        await ledger.recordFailure([building.chunkId]);
        return const _Outcome.retry(Duration.zero, 'split batch');
      } catch (e) {
        if (isDefinitiveUploadRejection(e)) return _failed(batch, 'upload rejected: $e');
        return _transient('upload error: $e');
      } finally {
        for (final file in files) {
          try {
            if (await file.exists()) await file.delete();
          } catch (_) {}
        }
      }
    }

    final deadline = DateTime.now().add(pollBudget);
    while (true) {
      final fetch = await fetchJob(jobId);
      switch (fetch.outcome) {
        case SyncJobFetchOutcome.ok:
          final status = fetch.status!;
          if (status.isSuccess) return const _Outcome.success();
          if (status.isTerminal) {
            await ledger.clearJob(ids);
            return _failed(batch, 'job ${status.status}: ${status.error ?? status.reasonCode ?? ''}');
          }
        case SyncJobFetchOutcome.notFound:
          // Job expired or unknown: upload again (the backend dedupes identical content).
          await ledger.clearJob(ids);
          return const _Outcome.retry(Duration(seconds: 5), 'job not found');
        case SyncJobFetchOutcome.transient:
          break;
      }
      if (DateTime.now().isAfter(deadline)) {
        // Keep the job id; the next drain resumes polling instead of re-uploading.
        return const _Outcome.retry(Duration(seconds: 30), 'job still processing');
      }
      await _sleep(pollInterval);
    }
  }

  /// The server examined the audio and refused it (decode failure / too large). Network
  /// errors, 5xx, auth and in-progress conflicts are transient and never count toward
  /// quarantine, so an outage cannot discard audio.
  @visibleForTesting
  static bool isDefinitiveUploadRejection(Object error) {
    final text = error.toString();
    return text.contains('could not be processed') || text.contains('too large');
  }

  _Outcome _transient(String reason) {
    _transientStreak++;
    return _Outcome.retry(backoffFor(_transientStreak), reason);
  }

  Future<_Outcome> _failed(List<WatchChunk> batch, String reason) async {
    if (batch.length > 1) {
      // Retry the oldest chunk alone next time; the rest follow once it succeeds.
      await ledger.recordFailure([batch.first.chunkId]);
      return _Outcome.retry(backoffFor(1), reason);
    }
    final id = batch.first.chunkId;
    await ledger.recordFailure([id]);
    final failures = ledger.failures(id);
    if (failures >= maxAttempts) return _Outcome.permanent('$reason (after $failures attempts)');
    return _Outcome.retry(backoffFor(failures), reason);
  }
}

enum _OutcomeKind { success, retry, permanent }

class _Outcome {
  final _OutcomeKind kind;
  final Duration? retryAfter;
  final String reason;

  const _Outcome.success()
      : kind = _OutcomeKind.success,
        retryAfter = null,
        reason = '';
  const _Outcome.retry(Duration this.retryAfter, this.reason) : kind = _OutcomeKind.retry;
  const _Outcome.permanent(this.reason)
      : kind = _OutcomeKind.permanent,
        retryAfter = null;
}

// ---------------------------------------------------------------------------------------
// Production bindings
// ---------------------------------------------------------------------------------------

/// Reads the native inbox directory (`Documents/watch_chunks`).
class FileWatchChunkStore implements WatchChunkStore {
  FileWatchChunkStore(this.directory, {Future<Directory> Function()? tempDirectory})
      : _tempDirectory = tempDirectory ?? getTemporaryDirectory;

  final String directory;
  final Future<Directory> Function() _tempDirectory;

  /// Quarantined chunks kept on the phone for manual recovery, capped by size.
  static const int maxQuarantineBytes = 200 * 1024 * 1024;

  @override
  Future<List<WatchChunk>> list() async {
    final dir = Directory(directory);
    if (!await dir.exists()) return const [];
    final chunks = <WatchChunk>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final json = jsonDecode(await entity.readAsString());
        if (json is! Map<String, dynamic>) continue;
        final chunk = WatchChunk.fromSidecar(json, directory: directory);
        if (chunk != null && await File(chunk.audioPath).exists()) chunks.add(chunk);
      } catch (e) {
        Logger.debug('[WatchChunks] unreadable sidecar ${entity.path}: $e');
      }
    }
    chunks.sort((a, b) => a.startedAtMs.compareTo(b.startedAtMs));
    return chunks;
  }

  @override
  Future<File> buildUploadFile(WatchChunk chunk) async {
    final wav = WatchChunkCodec.parseWav(await File(chunk.audioPath).readAsBytes());
    final bin = WatchChunkCodec.pcmToSyncBin(wav.pcm, channels: wav.channels);
    final temp = await _tempDirectory();
    final name = WatchChunkCodec.uploadFileName(
      startedAtMs: chunk.startedAtMs,
      sampleRate: wav.sampleRate,
      channels: wav.channels,
    );
    final file = File('${temp.path}/$name');
    await file.writeAsBytes(bin, flush: true);
    return file;
  }

  @override
  Future<void> delete(WatchChunk chunk) async {
    for (final path in [chunk.audioPath, chunk.metaPath]) {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (e) {
        Logger.debug('[WatchChunks] delete failed $path: $e');
      }
    }
  }

  @override
  Future<void> quarantine(WatchChunk chunk) async {
    final failedDir = Directory('$directory/failed');
    await failedDir.create(recursive: true);
    for (final path in [chunk.audioPath, chunk.metaPath]) {
      final file = File(path);
      if (await file.exists()) {
        await file.rename('${failedDir.path}/${path.split('/').last}');
      }
    }
    await _trimQuarantine(failedDir);
  }

  @override
  Future<List<String>> requeueQuarantined({Duration maxAge = const Duration(days: 3)}) async {
    final failedDir = Directory('$directory/failed');
    if (!await failedDir.exists()) return const [];
    final ids = <String>[];
    final cutoff = DateTime.now().subtract(maxAge);
    await for (final entity in failedDir.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final id = entity.uri.pathSegments.last.replaceAll('.json', '');
      final audio = File('${failedDir.path}/$id.wav');
      if (!await audio.exists() || (await entity.stat()).modified.isBefore(cutoff)) continue;
      await audio.rename('$directory/$id.wav');
      await entity.rename('$directory/$id.json');
      ids.add(id);
    }
    return ids;
  }

  Future<void> _trimQuarantine(Directory failedDir) async {
    final files = await failedDir.list().where((e) => e is File).cast<File>().toList();
    final stats = <File, FileStat>{for (final f in files) f: await f.stat()};
    files.sort((a, b) => stats[a]!.modified.compareTo(stats[b]!.modified));
    var total = stats.values.fold<int>(0, (sum, s) => sum + s.size);
    for (final file in files) {
      if (total <= maxQuarantineBytes) break;
      total -= stats[file]!.size;
      await file.delete();
    }
  }
}

/// SharedPreferences-backed ledger.
class PrefsWatchChunkLedger implements WatchChunkLedger {
  PrefsWatchChunkLedger(this._prefs) {
    _done.addAll(_prefs.getStringList(_doneKey) ?? const []);
    final rawJobs = _prefs.getString(_jobsKey);
    if (rawJobs != null) {
      try {
        _jobs.addAll(Map<String, String>.from(jsonDecode(rawJobs) as Map));
      } catch (_) {}
    }
    final rawFailures = _prefs.getString(_failuresKey);
    if (rawFailures != null) {
      try {
        _failures.addAll(Map<String, int>.from(jsonDecode(rawFailures) as Map));
      } catch (_) {}
    }
  }

  static const _doneKey = 'watchChunks.doneIds';
  static const _jobsKey = 'watchChunks.jobs';
  static const _failuresKey = 'watchChunks.failures';
  static const int maxDoneIds = 3000;

  final SharedPreferences _prefs;
  final List<String> _done = [];
  final Map<String, String> _jobs = {};
  final Map<String, int> _failures = {};

  @override
  bool isDone(String chunkId) => _done.contains(chunkId);

  @override
  Future<void> markDone(Iterable<String> chunkIds) async {
    for (final id in chunkIds) {
      if (!_done.contains(id)) _done.add(id);
      _failures.remove(id);
    }
    if (_done.length > maxDoneIds) _done.removeRange(0, _done.length - maxDoneIds);
    await _prefs.setStringList(_doneKey, _done);
    await _prefs.setString(_failuresKey, jsonEncode(_failures));
  }

  @override
  String? jobFor(String chunkId) => _jobs[chunkId];

  @override
  Future<void> setJob(Iterable<String> chunkIds, String jobId) async {
    for (final id in chunkIds) {
      _jobs[id] = jobId;
    }
    await _prefs.setString(_jobsKey, jsonEncode(_jobs));
  }

  @override
  Future<void> clearJob(Iterable<String> chunkIds) async {
    for (final id in chunkIds) {
      _jobs.remove(id);
    }
    await _prefs.setString(_jobsKey, jsonEncode(_jobs));
  }

  @override
  int failures(String chunkId) => _failures[chunkId] ?? 0;

  @override
  Future<void> recordFailure(Iterable<String> chunkIds) async {
    for (final id in chunkIds) {
      _failures[id] = (_failures[id] ?? 0) + 1;
    }
    await _prefs.setString(_failuresKey, jsonEncode(_failures));
  }

  @override
  Future<void> forget(Iterable<String> chunkIds) async {
    for (final id in chunkIds) {
      _done.remove(id);
      _jobs.remove(id);
      _failures.remove(id);
    }
    await _prefs.setStringList(_doneKey, _done);
    await _prefs.setString(_jobsKey, jsonEncode(_jobs));
    await _prefs.setString(_failuresKey, jsonEncode(_failures));
  }
}

/// App-wide owner: listens for native "chunkReceived" pokes, drains on startup, on a
/// periodic timer, on connectivity restore, and after each retry delay. iOS only.
class WatchChunkSyncService {
  WatchChunkSyncService._();

  static final WatchChunkSyncService instance = WatchChunkSyncService._();
  static const MethodChannel _channel = MethodChannel('com.omi.watch/chunks');

  WatchChunkSyncQueue? _queue;
  Timer? _periodic;
  Timer? _retry;
  StreamSubscription<bool>? _connectivity;
  bool Function()? _canUpload;
  bool _started = false;

  Future<void> start({required bool Function() canUpload, Stream<bool>? connectivityChanges}) async {
    if (_started || !Platform.isIOS) return;
    _started = true;
    _canUpload = canUpload;
    try {
      final inbox = await _channel.invokeMethod<String>('getInboxPath');
      if (inbox == null) {
        _started = false;
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      final store = FileWatchChunkStore(inbox);
      final ledger = PrefsWatchChunkLedger(prefs);
      // Give quarantined chunks one more round per app launch (e.g. after a long outage).
      final requeued = await store.requeueQuarantined();
      if (requeued.isNotEmpty) {
        await ledger.forget(requeued);
        Logger.debug('[WatchChunks] re-queued ${requeued.length} quarantined chunk(s)');
      }
      _queue = WatchChunkSyncQueue(
        store: store,
        ledger: ledger,
        uploader: (files) => SyncUploadGate.instance.upload(files),
        fetchJob: fetchSyncJobStatus,
        ack: _ack,
      );
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'chunkReceived') unawaited(poke('chunkReceived'));
        return null;
      });
      _connectivity = connectivityChanges?.listen((connected) {
        if (connected) unawaited(poke('connectivity'));
      });
      _periodic = Timer.periodic(const Duration(minutes: 1), (_) => unawaited(poke('periodic')));
      unawaited(poke('startup'));
    } catch (e) {
      _started = false;
      Logger.debug('[WatchChunks] start failed: $e');
    }
  }

  Future<bool> _ack(List<String> ids) async {
    try {
      return await _channel.invokeMethod<bool>('ackChunks', {'chunkIds': ids}) ?? false;
    } catch (e) {
      Logger.debug('[WatchChunks] ack failed: $e');
      return false;
    }
  }

  Future<void> poke(String reason) async {
    final queue = _queue;
    if (queue == null || queue.isDraining) return;
    if (!(_canUpload?.call() ?? false)) return;
    int? taskId;
    try {
      taskId = await _channel.invokeMethod<int>('beginBackgroundTask');
    } catch (_) {}
    try {
      final result = await queue.drain();
      if (result.uploaded > 0 || result.quarantined > 0) {
        Logger.debug(
          '[WatchChunks] drain($reason) uploaded=${result.uploaded} acked=${result.acknowledged} '
          'quarantined=${result.quarantined} stop=${result.stop.name}',
        );
      }
      if (result.stop == WatchChunkDrainStop.retryLater) {
        _retry?.cancel();
        _retry = Timer(result.retryAfter ?? const Duration(seconds: 30), () => unawaited(poke('retry')));
      }
    } catch (e) {
      Logger.debug('[WatchChunks] drain($reason) error: $e');
    } finally {
      if (taskId != null) {
        try {
          await _channel.invokeMethod<void>('endBackgroundTask', {'taskId': taskId});
        } catch (_) {}
      }
    }
  }

  Future<void> stop() async {
    _periodic?.cancel();
    _retry?.cancel();
    await _connectivity?.cancel();
    _started = false;
    _queue = null;
  }
}
