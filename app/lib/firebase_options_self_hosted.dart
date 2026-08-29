import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      throw UnsupportedError('Self-hosted Firebase is not configured for web.');
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.android:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
        throw UnsupportedError('Self-hosted Firebase is currently configured only for iOS.');
    }
  }

  static const ios = FirebaseOptions(
    apiKey: String.fromEnvironment('OMI_FIREBASE_API_KEY'),
    appId: String.fromEnvironment('OMI_FIREBASE_APP_ID'),
    messagingSenderId: String.fromEnvironment('OMI_FIREBASE_MESSAGING_SENDER_ID'),
    projectId: String.fromEnvironment('OMI_FIREBASE_PROJECT_ID', defaultValue: 'cason-omi'),
    storageBucket: String.fromEnvironment(
      'OMI_FIREBASE_STORAGE_BUCKET',
      defaultValue: 'cason-omi.firebasestorage.app',
    ),
    iosBundleId: String.fromEnvironment(
      'OMI_IOS_BUNDLE_ID',
      defaultValue: 'com.omi.omi-corp-boot',
    ),
    iosClientId: String.fromEnvironment('OMI_FIREBASE_IOS_CLIENT_ID'),
  );
}
