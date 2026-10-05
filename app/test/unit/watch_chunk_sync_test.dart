import 'package:flutter_test/flutter_test.dart';

import 'package:omi/services/watch_chunks/watch_chunk_sync.dart';

void main() {
  group('buildWatchChunkSyncConfig', () {
    test('passes static headers and firebase options, never an auth header', () {
      final config = buildWatchChunkSyncConfig(
        enabled: true,
        apiBaseUrl: 'https://api.example.com/',
        headers: {'X-App-Platform': 'ios', 'Authorization': 'Bearer stale'},
        firebase: {'apiKey': 'k', 'appId': 'a', 'messagingSenderId': 's', 'projectId': 'p', 'databaseURL': null},
      );
      expect(config['enabled'], isTrue);
      expect(config['apiBaseUrl'], 'https://api.example.com/');
      expect(config['headers'], {'X-App-Platform': 'ios'});
      expect(config['firebase'], {'apiKey': 'k', 'appId': 'a', 'messagingSenderId': 's', 'projectId': 'p'});
      expect(config.containsKey('legacyDoneIds'), isFalse);
      expect(config.containsKey('legacyJobs'), isFalse);
      expect(config.containsKey('requeueQuarantined'), isFalse);
    });

    test('groups the legacy chunk->job ledger by job for native import', () {
      final config = buildWatchChunkSyncConfig(
        enabled: true,
        apiBaseUrl: 'https://api.example.com/',
        headers: const {},
        firebase: const {},
        legacyDoneIds: ['c0'],
        legacyJobsByChunk: {'c1': 'job-a', 'c2': 'job-a', 'c3': 'job-b', 'c4': ''},
        requeueQuarantined: true,
      );
      expect(config['legacyDoneIds'], ['c0']);
      expect(config['legacyJobs'], {
        'job-a': ['c1', 'c2'],
        'job-b': ['c3'],
      });
      expect(config['requeueQuarantined'], isTrue);
    });
  });

  group('readLegacyWatchChunkLedger', () {
    test('tolerates missing and corrupt prefs', () {
      expect(readLegacyWatchChunkLedger(null, null).doneIds, isEmpty);
      expect(readLegacyWatchChunkLedger(null, 'not json').jobsByChunk, isEmpty);
      final ledger = readLegacyWatchChunkLedger(['a'], '{"c1":"job"}');
      expect(ledger.doneIds, ['a']);
      expect(ledger.jobsByChunk, {'c1': 'job'});
    });
  });
}
