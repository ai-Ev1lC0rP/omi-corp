import 'package:flutter_test/flutter_test.dart';

import 'package:omi/env/env.dart';
import 'package:omi/providers/auth_provider.dart';
import 'package:omi/services/auth/auth_token_result.dart';

class _TestEnvFields implements EnvFields {
  @override
  String? get posthogApiKey => null;
  @override
  String? get apiBaseUrl => null;
  @override
  String? get googleMapsApiKey => null;
  @override
  String? get intercomAppId => null;
  @override
  String? get intercomIOSApiKey => null;
  @override
  String? get intercomAndroidApiKey => null;
  @override
  String? get googleClientId => null;
  @override
  String? get googleClientSecret => null;
  @override
  bool? get useWebAuth => false;
  @override
  bool? get useAuthCustomToken => false;
}

void main() {
  setUpAll(() => Env.init(_TestEnvFields()));

  group('AuthenticationProvider loading', () {
    test('setLoadingState and setLoading drive the same observable flag', () {
      final provider = AuthenticationProvider(initializeListeners: false);
      var notifications = 0;
      provider.addListener(() => notifications++);

      expect(provider.loading, isFalse);
      provider.setLoadingState(true);
      expect(provider.loading, isTrue);
      provider.setLoading(false);
      expect(provider.loading, isFalse);
      provider.setLoading(true);
      expect(provider.loading, isTrue);
      expect(notifications, 3);
    });

    test('a sign-in tap while a sign-in is running is ignored', () async {
      final provider = AuthenticationProvider(initializeListeners: false);
      provider.setLoadingState(true);
      var signedIn = false;

      await provider.onGoogleSignIn(() => signedIn = true);
      await provider.onAppleSignIn(() => signedIn = true);

      expect(signedIn, isFalse);
      expect(provider.loading, isTrue, reason: 'the running attempt still owns the spinner');
    });
  });

  group('sign-in failure messages', () {
    test('backend token rejection gets a specific message', () {
      expect(
        AuthenticationProvider.signInFailureMessageFor(AuthSessionExpirationReason.backendRejectedRefreshedToken),
        AuthenticationProvider.backendRejectedSignInMessage,
      );
      expect(
          AuthenticationProvider.backendRejectedSignInMessage, contains("backend doesn't trust this Firebase project"));
    });

    test('other expiries and no expiry fall back to the generic text', () {
      expect(AuthenticationProvider.signInFailureMessageFor(null), isNull);
      for (final reason in AuthSessionExpirationReason.values) {
        if (reason == AuthSessionExpirationReason.backendRejectedRefreshedToken) continue;
        expect(AuthenticationProvider.signInFailureMessageFor(reason), isNull, reason: reason.name);
      }
    });
  });
}
