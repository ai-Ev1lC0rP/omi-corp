Future<T> initializeDefaultFirebaseApp<T>({
  required Future<T> Function() initialize,
  required T Function() existingApp,
  required String? Function(Object error) errorCode,
}) async {
  try {
    return await initialize();
  } catch (error) {
    if (errorCode(error) == 'duplicate-app') {
      return existingApp();
    }
    rethrow;
  }
}
