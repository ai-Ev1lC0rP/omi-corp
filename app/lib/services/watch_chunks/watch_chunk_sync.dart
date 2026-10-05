import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:omi/env/env.dart';
import 'package:omi/services/account_cutover/account_cutover_runtime.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/utils/platform/platform_manager.dart';

/// Prefs keys of the Dart queue that owned watch-chunk uploads before native iOS took over.
/// Read once, handed to native for dedupe, then removed.
const String legacyWatchChunkDoneIdsKey = 'watchChunks.doneIds';
const String legacyWatchChunkJobsKey = 'watchChunks.jobs';
const String legacyWatchChunkFailuresKey = 'watchChunks.failures';

/// Builds the `configureSync` payload for the native iOS watch-chunk uploader.
///
/// Native code (`WatchChunkSync.swift`) is the single owner of upload, server-job
/// confirmation and the watch ack, so it works while the Flutter app is suspended or not
/// running. It needs the API base URL, the static request headers Dart would send, and the
/// Firebase options so it can initialise Firebase and mint ID tokens on a background launch.
@visibleForTesting
Map<String, Object?> buildWatchChunkSyncConfig({
  required bool enabled,
  required String apiBaseUrl,
  required Map<String, String> headers,
  required Map<String, String?> firebase,
  List<String> legacyDoneIds = const [],
  Map<String, String> legacyJobsByChunk = const {},
  bool requeueQuarantined = false,
}) {
  final jobs = <String, List<String>>{};
  legacyJobsByChunk.forEach((chunkId, jobId) {
    if (jobId.isEmpty) return;
    jobs.putIfAbsent(jobId, () => []).add(chunkId);
  });
  return {
    'enabled': enabled,
    'apiBaseUrl': apiBaseUrl,
    'headers': Map<String, String>.of(headers)..removeWhere((k, _) => k == 'Authorization'),
    'firebase': {
      for (final entry in firebase.entries)
        if (entry.value != null && entry.value!.isNotEmpty) entry.key: entry.value,
    },
    if (legacyDoneIds.isNotEmpty) 'legacyDoneIds': legacyDoneIds,
    if (jobs.isNotEmpty) 'legacyJobs': jobs,
    if (requeueQuarantined) 'requeueQuarantined': true,
  };
}

/// Parses the legacy Dart ledger (`watchChunks.doneIds` list, `watchChunks.jobs` JSON map).
@visibleForTesting
({List<String> doneIds, Map<String, String> jobsByChunk}) readLegacyWatchChunkLedger(
  List<String>? doneIds,
  String? rawJobs,
) {
  var jobs = <String, String>{};
  if (rawJobs != null) {
    try {
      jobs = Map<String, String>.from(jsonDecode(rawJobs) as Map);
    } catch (_) {}
  }
  return (doneIds: doneIds ?? const [], jobsByChunk: jobs);
}

/// App-side bridge to the native iOS watch-chunk uploader. Sends configuration on start and
/// nudges native on connectivity changes and periodically while the app runs; all upload,
/// confirmation and ack logic (and the dedupe ledger) lives natively.
class WatchChunkSyncService {
  WatchChunkSyncService._();

  static final WatchChunkSyncService instance = WatchChunkSyncService._();
  static const MethodChannel _channel = MethodChannel('com.omi.watch/chunks');

  Timer? _periodic;
  StreamSubscription<bool>? _connectivity;
  bool Function()? _canUpload;
  bool _started = false;
  bool _legacyMigrated = false;
  bool _requeueSent = false;

  Future<void> start({required bool Function() canUpload, Stream<bool>? connectivityChanges}) async {
    if (_started || !Platform.isIOS) return;
    _started = true;
    _canUpload = canUpload;
    _connectivity = connectivityChanges?.listen((connected) {
      if (connected) unawaited(_sync('connectivity'));
    });
    // Refresh config (account generation, app build) and nudge while foregrounded. Native
    // also runs on its own: WatchConnectivity deliveries, URLSession events, BG tasks.
    _periodic = Timer.periodic(const Duration(minutes: 1), (_) => unawaited(_sync('periodic')));
    await _sync('startup');
  }

  Future<void> stop() async {
    _periodic?.cancel();
    _periodic = null;
    await _connectivity?.cancel();
    _connectivity = null;
    _started = false;
  }

  Future<void> _sync(String reason) async {
    if (!(_canUpload?.call() ?? false)) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final legacy = _legacyMigrated
          ? (doneIds: const <String>[], jobsByChunk: const <String, String>{})
          : readLegacyWatchChunkLedger(
              prefs.getStringList(legacyWatchChunkDoneIdsKey),
              prefs.getString(legacyWatchChunkJobsKey),
            );
      final options = Firebase.app().options;
      final config = buildWatchChunkSyncConfig(
        enabled: !Env.profile.usesFirebaseAuthEmulator,
        apiBaseUrl: Env.apiBaseUrl ?? '',
        headers: _staticHeaders(),
        firebase: {
          'apiKey': options.apiKey,
          'appId': options.appId,
          'messagingSenderId': options.messagingSenderId,
          'projectId': options.projectId,
          'storageBucket': options.storageBucket,
          'databaseURL': options.databaseURL,
        },
        legacyDoneIds: legacy.doneIds,
        legacyJobsByChunk: legacy.jobsByChunk,
        requeueQuarantined: !_requeueSent,
      );
      final status = await _channel.invokeMethod<Object?>('configureSync', config);
      _requeueSent = true;
      if (!_legacyMigrated) {
        _legacyMigrated = true;
        await prefs.remove(legacyWatchChunkDoneIdsKey);
        await prefs.remove(legacyWatchChunkJobsKey);
        await prefs.remove(legacyWatchChunkFailuresKey);
      }
      if (reason == 'startup') Logger.debug('[WatchChunks] native sync configured: $status');
    } catch (e) {
      Logger.debug('[WatchChunks] native sync ($reason) failed: $e');
    }
  }

  Map<String, String> _staticHeaders() {
    final platform = PlatformManager.instance;
    final headers = <String, String>{
      'X-App-Platform': platform.platform,
      'X-Device-Id-Hash': platform.deviceIdHash,
      'X-App-Version': platform.appVersion,
      'X-App-Build': platform.appBuild,
    };
    // Same rule as buildHeaders for an authenticated mutating request: positive account
    // generations must accompany the upload.
    final generation = AccountCutoverRuntime.instance.control.accountGeneration;
    if (generation > 0) headers['X-Account-Generation'] = generation.toString();
    return headers;
  }
}
