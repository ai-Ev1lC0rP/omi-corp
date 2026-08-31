import 'package:flutter_test/flutter_test.dart';
import 'package:omi/startup/firebase_app_initializer.dart';

class _FirebaseInitializationError implements Exception {
  const _FirebaseInitializationError(this.code);

  final String code;
}

void main() {
  test('returns the existing default app when native initialization wins the race', () async {
    var existingAppReads = 0;

    final app = await initializeDefaultFirebaseApp<String>(
      initialize: () async => throw const _FirebaseInitializationError('duplicate-app'),
      existingApp: () {
        existingAppReads += 1;
        return 'native-default-app';
      },
      errorCode: (error) => (error as _FirebaseInitializationError).code,
    );

    expect(app, 'native-default-app');
    expect(existingAppReads, 1);
  });

  test('does not hide Firebase initialization failures other than duplicate-app', () async {
    const failure = _FirebaseInitializationError('invalid-options');

    await expectLater(
      initializeDefaultFirebaseApp<String>(
        initialize: () async => throw failure,
        existingApp: () => 'native-default-app',
        errorCode: (error) => (error as _FirebaseInitializationError).code,
      ),
      throwsA(same(failure)),
    );
  });
}
