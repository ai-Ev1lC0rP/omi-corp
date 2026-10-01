import 'dart:async';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:omi/backend/http/api/apps.dart' as apps_api;
import 'package:omi/backend/preferences.dart';
import 'package:omi/env/env.dart';
import 'package:omi/app_globals.dart';
import 'package:omi/providers/base_provider.dart';
import 'package:omi/services/account_cutover/account_cutover_runtime.dart';
import 'package:omi/services/auth_service.dart';
import 'package:omi/services/auth/auth_token_result.dart';
import 'package:omi/services/notifications.dart';
import 'package:omi/utils/auth/clear_user_state.dart';
import 'package:omi/utils/alerts/app_snackbar.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/utils/platform/platform_manager.dart';
import 'package:omi/utils/platform/platform_service.dart';

/// Runs a provider-link helper, then migrates only the anonymous source proof
/// it returned after the destination account has been established.
Future<ProviderLinkResult?> completeProviderLinkAndMigrate({
  required Future<ProviderLinkResult?> Function() linkProvider,
  required Future<bool> Function(String sourceUid, String sourceToken) migrate,
}) async {
  final result = await linkProvider();
  final source = result?.anonymousSourceMigration;
  final destinationUid = result?.destinationUid;
  if (source != null && destinationUid != null && destinationUid != source.uid) {
    await migrate(source.uid, source.token);
  }
  return result;
}

class AuthenticationProvider extends BaseProvider {
  FirebaseAuth get _auth => FirebaseAuth.instance;

  User? user;
  String? authToken;
  bool _requiresReauthentication = false;
  int _sessionExpirationGeneration = 0;
  StreamSubscription<User?>? _authStateSubscription;
  StreamSubscription<User?>? _idTokenSubscription;
  StreamSubscription<AuthSessionExpiredEvent>? _sessionExpiredSubscription;
  bool get requiresReauthentication => _requiresReauthentication;
  int get sessionExpirationGeneration => _sessionExpirationGeneration;

  AuthenticationProvider({bool initializeListeners = true}) {
    if (initializeListeners) _initializeAuthListeners();
  }

  void _initializeAuthListeners() {
    // DEBUG: Log initial state
    Logger.debug(
      'DEBUG AuthProvider: Initial currentUser=${_auth.currentUser?.uid}, isAnonymous=${_auth.currentUser?.isAnonymous}',
    );

    Future.microtask(() {
      _authStateSubscription = _auth.authStateChanges().distinct((p, n) => p?.uid == n?.uid).listen((User? user) {
        AuthService.instance.handleAuthUserChanged(user?.uid);
        Logger.debug(
          'DEBUG AuthProvider: authStateChanges fired - user=${user?.uid}, isAnonymous=${user?.isAnonymous}',
        );
        this.user = user;
        // Only update SharedPreferences if Firebase has a user
        // Don't clear cached credentials - allows fallback for dev builds
        if (user != null) {
          SharedPreferencesUtil().uid = user.uid;
          SharedPreferencesUtil().email = user.email ?? '';
          SharedPreferencesUtil().givenName = user.displayName?.split(' ')[0] ?? '';
        }
        final cutoverOwner = (user != null && !user.isAnonymous) ? user.uid : null;
        unawaited(AccountCutoverRuntime.instance.bindAuthenticatedOwner(cutoverOwner));
        notifyListeners();
      });
      _idTokenSubscription = _auth.idTokenChanges().distinct((p, n) => p?.uid == n?.uid).listen((User? user) async {
        AuthService.instance.handleAuthUserChanged(user?.uid);
        if (user == null) {
          Logger.debug('User is currently signed out or the token has been revoked!');
          SharedPreferencesUtil().authToken = '';
          SharedPreferencesUtil().tokenExpirationTime = 0;
          authToken = null;
        } else {
          Logger.debug('User is signed in at ${DateTime.now()} with user ${user.uid}');
          try {
            if (_requiresReauthentication ||
                SharedPreferencesUtil().authToken.isEmpty ||
                DateTime.now().millisecondsSinceEpoch > SharedPreferencesUtil().tokenExpirationTime) {
              authToken = await AuthService.instance.getIdToken();
            }
            if (authToken != null && authToken!.isNotEmpty) {
              _requiresReauthentication = false;
            }
          } catch (e) {
            authToken = null;
            Logger.debug('Failed to get token: $e');
          }
        }
        notifyListeners();
      });
      _sessionExpiredSubscription = AuthService.instance.sessionExpiredEvents.listen((event) {
        _requiresReauthentication = true;
        _sessionExpirationGeneration++;
        user = null;
        authToken = null;
        final rootContext = globalNavigatorKey.currentContext;
        if (rootContext != null && rootContext.mounted) {
          clearAllUserState(rootContext);
        }
        notifyListeners();
      });
    });
  }

  bool isSignedIn() {
    return !_requiresReauthentication && _auth.currentUser != null && !_auth.currentUser!.isAnonymous;
  }

  bool get _hasFirebaseUser => _auth.currentUser != null && !_auth.currentUser!.isAnonymous;

  @override
  void dispose() {
    _authStateSubscription?.cancel();
    _idTokenSubscription?.cancel();
    _sessionExpiredSubscription?.cancel();
    super.dispose();
  }

  /// Shown when the backend rejects a freshly minted Firebase ID token during
  /// sign-in. That happens when the app's Firebase project is not the one the
  /// backend verifies tokens against (e.g. a personal Firebase project paired
  /// with api.omi.me).
  static const backendRejectedSignInMessage = "Server rejected sign-in (backend doesn't trust this Firebase project).";

  /// Maps a session expiry observed during a sign-in attempt to a specific
  /// user-facing message, or null when the generic failure text applies.
  @visibleForTesting
  static String? signInFailureMessageFor(AuthSessionExpirationReason? reason) {
    if (reason == AuthSessionExpirationReason.backendRejectedRefreshedToken) {
      return backendRejectedSignInMessage;
    }
    return null;
  }

  /// Single loading state for the provider. Both [setLoading] and
  /// [setLoadingState] drive [loading], so the auth spinner and the
  /// double-tap guard observe the same flag.
  void setLoading(bool value) => setLoadingState(value);

  Future<void> onGoogleSignIn(Function() onSignIn) {
    final useWebAuth = Env.useWebAuth;
    return _runProviderSignIn(
      providerName: 'Google',
      authenticate: () {
        if (PlatformService.isMobile && !useWebAuth) {
          return AuthService.instance.signInWithGoogleMobile();
        }
        return AuthService.instance.authenticateWithProvider('google');
      },
      providerFailureMessage: () =>
          globalNavigatorKey.currentContext?.l10n.authFailedToSignInWithGoogle ??
          'Failed to sign in with Google, please try again.',
      onSignIn: onSignIn,
    );
  }

  Future<void> onAppleSignIn(Function() onSignIn) {
    final useWebAuth = Env.useWebAuth;
    return _runProviderSignIn(
      providerName: 'Apple',
      authenticate: () {
        if (PlatformService.isMobile && !useWebAuth && !Platform.isAndroid) {
          return AuthService.instance.signInWithAppleMobile();
        }
        return AuthService.instance.authenticateWithProvider('apple');
      },
      providerFailureMessage: () =>
          globalNavigatorKey.currentContext?.l10n.authFailedToSignInWithApple ??
          'Failed to sign in with Apple, please try again.',
      onSignIn: onSignIn,
    );
  }

  /// Shared provider sign-in flow. [loading] is held for the whole attempt so
  /// the spinner shows and repeated taps are ignored. Any session expiry
  /// emitted while the attempt runs (the post-sign-in backend calls expire the
  /// session when the backend rejects the token) selects a specific error.
  Future<void> _runProviderSignIn({
    required String providerName,
    required Future<UserCredential?> Function() authenticate,
    required String Function() providerFailureMessage,
    required Function() onSignIn,
  }) async {
    if (loading) return;
    setLoadingState(true);
    AuthSessionExpirationReason? sessionExpiry;
    final expirySubscription = AuthService.instance.sessionExpiredEvents.listen((event) {
      sessionExpiry = event.reason;
    });
    try {
      final credential = await authenticate();
      final rejection = signInFailureMessageFor(sessionExpiry);
      if (rejection != null) {
        Logger.debug('$providerName sign in: backend rejected the Firebase ID token');
        AppSnackbar.showSnackbarError(rejection);
      } else if (credential != null && _hasFirebaseUser) {
        await _signIn(onSignIn);
      } else {
        AppSnackbar.showSnackbarError(providerFailureMessage());
      }
    } catch (e) {
      Logger.debug('OAuth $providerName sign in error: $e');
      AppSnackbar.showSnackbarError(
        signInFailureMessageFor(sessionExpiry) ??
            globalNavigatorKey.currentContext?.l10n.authenticationFailed ??
            'Authentication failed. Please try again.',
      );
    } finally {
      await expirySubscription.cancel();
      setLoadingState(false);
    }
  }

  Future<String?> _getIdToken() async {
    try {
      final token = await AuthService.instance.getIdToken();
      NotificationService.instance.saveNotificationToken();

      Logger.debug('Firebase token retrieved successfully');
      return token;
    } catch (e, stackTrace) {
      AppSnackbar.showSnackbarError(
        globalNavigatorKey.currentContext?.l10n.authFailedToRetrieveToken ??
            'Failed to retrieve firebase token, please try again.',
      );
      PlatformManager.instance.crashReporter.reportCrash(e, stackTrace);

      return null;
    }
  }

  Future<void> _signIn(Function() onSignIn) async {
    final token = await _getIdToken();

    if (token != null) {
      User currentUser;
      try {
        currentUser = FirebaseAuth.instance.currentUser!;
      } catch (e, stackTrace) {
        AppSnackbar.showSnackbarError(
          globalNavigatorKey.currentContext?.l10n.authUnexpectedErrorFirebase ??
              'Unexpected error signing in, Firebase error, please try again.',
        );

        PlatformManager.instance.crashReporter.reportCrash(e, stackTrace);
        return;
      }
      final newUid = currentUser.uid;
      SharedPreferencesUtil().uid = newUid;
      user = currentUser;
      authToken = token;
      _requiresReauthentication = false;
      PlatformManager.instance.analytics.identify();
      notifyListeners();
      onSignIn();
    } else {
      AppSnackbar.showSnackbarError(
        globalNavigatorKey.currentContext?.l10n.authUnexpectedError ?? 'Unexpected error signing in, please try again',
      );
    }
  }

  void openTermsOfService() {
    _launchUrl('https://www.omi.me/pages/terms-of-service');
  }

  void openPrivacyPolicy() {
    _launchUrl('https://www.omi.me/pages/privacy');
  }

  void _launchUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      Logger.debug('Invalid URL');
      return;
    }

    await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
  }

  Future<void> linkWithGoogle() async {
    setLoading(true);
    try {
      final result = await completeProviderLinkAndMigrate(
        linkProvider: AuthService.instance.linkWithGoogle,
        migrate: migrateAppOwnerId,
      );
      if (result == null) {
        setLoading(false);
        return;
      }
    } catch (e) {
      AppSnackbar.showSnackbarError(
        globalNavigatorKey.currentContext?.l10n.authFailedToLinkGoogle ??
            'Failed to link with Google, please try again.',
      );
      rethrow;
    } finally {
      setLoading(false);
    }
  }

  Future<void> linkWithApple() async {
    setLoading(true);
    try {
      final appleProvider = AppleAuthProvider();
      try {
        await FirebaseAuth.instance.currentUser?.linkWithProvider(appleProvider);
      } catch (e) {
        if (e is FirebaseAuthException && e.code == 'credential-already-in-use') {
          // Get existing user credentials
          final existingCred = e.credential;
          final oldUserId = FirebaseAuth.instance.currentUser?.uid;
          final sourceToken = await FirebaseAuth.instance.currentUser?.getIdToken();

          // Sign out current anonymous user
          AuthService.instance.handleAuthUserChanged(null);
          await FirebaseAuth.instance.signOut();

          // Sign in with existing account
          await FirebaseAuth.instance.signInWithCredential(existingCred!);
          final newUserId = FirebaseAuth.instance.currentUser?.uid;
          if (newUserId != null) AuthService.instance.markAuthenticatedUser(newUserId);
          await AuthService.instance.getIdToken();

          SharedPreferencesUtil().onboardingCompleted = false;
          SharedPreferencesUtil().uid = newUserId ?? '';
          SharedPreferencesUtil().email = FirebaseAuth.instance.currentUser?.email ?? '';
          SharedPreferencesUtil().givenName = FirebaseAuth.instance.currentUser?.displayName?.split(' ')[0] ?? '';
          if (oldUserId != null && newUserId != null && sourceToken != null) {
            await migrateAppOwnerId(oldUserId, sourceToken);
          }
          return;
        }
        AppSnackbar.showSnackbarError(
          globalNavigatorKey.currentContext?.l10n.authFailedToLinkApple ??
              'Failed to link with Apple, please try again.',
        );
        rethrow;
      }
    } catch (e) {
      Logger.debug('Error linking with Apple: $e');
      AppSnackbar.showSnackbarError(
        globalNavigatorKey.currentContext?.l10n.authFailedToLinkApple ?? 'Failed to link with Apple, please try again.',
      );
      rethrow;
    } finally {
      setLoading(false);
    }
  }

  Future<bool> migrateAppOwnerId(String oldId, String sourceToken) async {
    return await apps_api.migrateAppOwnerId(oldId, sourceToken);
  }
}
