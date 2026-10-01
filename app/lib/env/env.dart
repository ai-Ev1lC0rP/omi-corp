import 'package:omi/flavors.dart';

import 'environment_profile.dart';

abstract class Env {
  static const productionApiBaseUrl = 'https://api.omi.me/';
  static const productionAgentProxyWsUrl = 'wss://agent.omi.me/v1/agent/ws';
  static const _apiBaseUrlFromDefine = String.fromEnvironment(
    'OMI_API_BASE_URL',
  );
  static const firebaseAuthEmulatorHost = String.fromEnvironment(
    'OMI_FIREBASE_AUTH_EMULATOR_HOST',
    defaultValue: '127.0.0.1',
  );
  static const _firebaseAuthEmulatorPort = String.fromEnvironment(
    'OMI_FIREBASE_AUTH_EMULATOR_PORT',
    defaultValue: '9099',
  );
  static late final EnvFields _instance;
  static String? _apiBaseUrlOverride;
  static String? _agentProxyWsUrlOverride;
  static bool isTestFlight = false;

  static AppEnvironmentProfile get profile => AppEnvironmentProfile.forFlavor(
        productionFlavor: F.env == Environment.prod,
      );

  static void init(EnvFields instance) {
    _instance = instance;
  }

  static void overrideApiBaseUrl(String url) {
    _apiBaseUrlOverride = url;
  }

  static void clearApiBaseUrlOverrideForTesting() {
    _apiBaseUrlOverride = null;
  }

  static void overrideAgentProxyWsUrl(String url) {
    _agentProxyWsUrlOverride = url;
  }

  static String? get posthogApiKey => _instance.posthogApiKey;

  // static String? get apiBaseUrl => 'https://omi-backend.ngrok.app/';
  static String? get apiBaseUrl {
    final url = _resolvedApiBaseUrl;
    // Request URLs are built as '${apiBaseUrl}v1/...', so a self-hosted host
    // supplied without a trailing slash is normalized here.
    if (url != null && url.isNotEmpty && profile.requiresExplicitApiBaseUrl && !url.endsWith('/')) {
      return '$url/';
    }
    return url;
  }

  static String? get _resolvedApiBaseUrl {
    if (_apiBaseUrlOverride != null) return _apiBaseUrlOverride;
    if (_apiBaseUrlFromDefine.isNotEmpty) return _apiBaseUrlFromDefine;
    final configuredApiBaseUrl = _instance.apiBaseUrl;
    if (configuredApiBaseUrl != null && configuredApiBaseUrl.isNotEmpty) {
      return configuredApiBaseUrl;
    }
    return profile.defaultApiBaseUrl;
  }

  static int get firebaseAuthEmulatorPort => int.tryParse(_firebaseAuthEmulatorPort) ?? 9099;

  static String get authCallbackScheme => profile.authCallbackScheme;

  static String get authRedirectUri => '$authCallbackScheme://auth/callback';

  /// OAuth remains on the production identity plane even when mobile Beta
  /// uses the development serving API for product traffic.
  static String get authApiBaseUrl => authApiBaseUrlForProfile(profile, servingApiBaseUrl: apiBaseUrl);

  static String authApiBaseUrlForProfile(
    AppEnvironmentProfile configuredProfile, {
    String? servingApiBaseUrl,
  }) {
    if (configuredProfile == AppEnvironmentProfile.mobileBeta) {
      return productionApiBaseUrl;
    }
    return servingApiBaseUrl ?? configuredProfile.defaultApiBaseUrl;
  }

  static void validateProfilePairing({
    bool? productionFlavor,
    AppEnvironmentProfile? configuredProfile,
  }) {
    final isProductionFlavor = productionFlavor ?? F.env == Environment.prod;
    final effectiveProfile = configuredProfile ?? profile;
    if (!isProductionFlavor && effectiveProfile != AppEnvironmentProfile.localDev) {
      throw StateError(
        'Profile ${effectiveProfile.name} must be built with the prod flavor.',
      );
    }
    if (isProductionFlavor && effectiveProfile == AppEnvironmentProfile.localDev) {
      throw StateError('The prod flavor cannot use the local_dev profile.');
    }
  }

  static void validateFirebaseProject({
    required String projectId,
    AppEnvironmentProfile? configuredProfile,
  }) {
    final effectiveProfile = configuredProfile ?? profile;
    if (projectId != effectiveProfile.firebaseProjectId) {
      throw StateError(
        'Mobile profile ${effectiveProfile.name} requires Firebase project ${effectiveProfile.firebaseProjectId}, '
        'but the app was initialized with $projectId.',
      );
    }
  }

  /// Production-family packages have one pinned backend authority. This runs
  /// during startup so a misconfigured signing group fails before networking.
  static void validateStartupRouting({
    required bool productionFamily,
    String? configuredApiBaseUrl,
    AppEnvironmentProfile? configuredProfile,
  }) {
    final effectiveProfile = configuredProfile ?? (productionFamily ? AppEnvironmentProfile.production : profile);
    final normalized = (configuredApiBaseUrl ?? apiBaseUrl ?? '').trim().replaceFirst(RegExp(r'/+$'), '');
    final expected = effectiveProfile.defaultApiBaseUrl.replaceFirst(
      RegExp(r'/+$'),
      '',
    );

    if (effectiveProfile == AppEnvironmentProfile.localDev) {
      if (!_isLocalDevelopmentApi(normalized)) {
        throw StateError(
          'Profile local_dev requires a loopback or private-network API endpoint; '
          'use mobile_beta for https://api.omiapi.com/.',
        );
      }
      return;
    }

    if (effectiveProfile.requiresExplicitApiBaseUrl) {
      _validateExplicitApiBaseUrl(effectiveProfile, normalized);
      return;
    }

    if (normalized != expected) {
      throw StateError(
        'Profile ${effectiveProfile.name} requires API_BASE_URL=${effectiveProfile.defaultApiBaseUrl}',
      );
    }

    if (effectiveProfile == AppEnvironmentProfile.production &&
        _agentProxyWsUrlFor(normalized) != productionAgentProxyWsUrl) {
      throw StateError(
        'Production packages require the production agent WebSocket endpoint.',
      );
    }
  }

  static void requireProductionRouting() => validateStartupRouting(productionFamily: true);

  /// Based Hardware serving planes. They verify ID tokens against the
  /// `based-hardware` Firebase project only, so a profile backed by any other
  /// Firebase project must never route to them.
  static const _basedHardwareApiHosts = {'api.omi.me', 'api.omiapi.com'};

  static void _validateExplicitApiBaseUrl(AppEnvironmentProfile profile, String normalized) {
    if (normalized.isEmpty) {
      throw StateError(
        'Profile ${profile.name} has no API base URL. Build with '
        '--dart-define=OMI_API_BASE_URL=https://<your-backend>/ or set API_BASE_URL in .env; '
        'it never falls back to $productionApiBaseUrl.',
      );
    }
    final uri = Uri.tryParse(normalized);
    if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http') || uri.host.isEmpty) {
      throw StateError(
        'Profile ${profile.name} requires an absolute http(s) API base URL, got "$normalized".',
      );
    }
    final host = uri.host.toLowerCase();
    if (_basedHardwareApiHosts.contains(host)) {
      throw StateError(
        'Profile ${profile.name} cannot use $host: that backend only trusts the based-hardware Firebase project, '
        'not ${profile.firebaseProjectId}. Point OMI_API_BASE_URL at a backend configured for '
        '${profile.firebaseProjectId}.',
      );
    }
  }

  /// WebSocket URL for the agent proxy service.
  /// Derives from apiBaseUrl: api.omi.me → agent.omi.me, api.omiapi.com → agent.omiapi.com.
  /// Can be overridden via Env.overrideAgentProxyWsUrl() for local testing.
  static String get agentProxyWsUrl {
    if (_agentProxyWsUrlOverride != null) return _agentProxyWsUrlOverride!;
    final base = apiBaseUrl ?? productionApiBaseUrl;
    if (profile.requiresExplicitApiBaseUrl) return selfHostedAgentProxyWsUrlFor(base);
    return _agentProxyWsUrlFor(base);
  }

  /// Self-hosted backends (profiles without a built-in API host) serve the
  /// agent proxy from the API's own origin: `https://h[:p]/` maps to
  /// `wss://h[:p]/v1/agent/ws` and `http://` maps to `ws://`. Never throws,
  /// whatever the host looks like; startup validation rejects unusable URLs.
  static String selfHostedAgentProxyWsUrlFor(String base) {
    final uri = Uri.tryParse(base.trim());
    if (uri == null || uri.host.isEmpty) return 'wss:///v1/agent/ws';
    return Uri(
      scheme: uri.scheme == 'http' ? 'ws' : 'wss',
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: '/v1/agent/ws',
    ).toString();
  }

  static String _agentProxyWsUrlFor(String base) {
    final host = Uri.parse(base).host.replaceFirst('api.', 'agent.');
    return 'wss://$host/v1/agent/ws';
  }

  static bool _isLocalDevelopmentApi(String base) {
    final uri = Uri.tryParse(base);
    if (uri == null || uri.host.isEmpty || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return false;
    }
    final host = uri.host.toLowerCase();
    if (host == 'localhost' || host == 'host.docker.internal' || host == '::1') {
      return true;
    }
    final octets = host.split('.').map(int.tryParse).toList();
    if (octets.length != 4 || octets.any((octet) => octet == null || octet < 0 || octet > 255)) {
      return false;
    }
    final first = octets[0]!;
    final second = octets[1]!;
    return first == 10 ||
        (first == 172 && second >= 16 && second <= 31) ||
        (first == 192 && second == 168) ||
        (first == 127);
  }

  static String? get googleMapsApiKey => _instance.googleMapsApiKey;

  static String? get intercomAppId => _instance.intercomAppId;

  static String? get intercomIOSApiKey => _instance.intercomIOSApiKey;

  static String? get intercomAndroidApiKey => _instance.intercomAndroidApiKey;

  static String? get googleClientId => _instance.googleClientId;

  static String? get googleClientSecret => _instance.googleClientSecret;

  static bool get useWebAuth => _instance.useWebAuth ?? false;

  static bool get useAuthCustomToken => _instance.useAuthCustomToken ?? false;
}

abstract class EnvFields {
  String? get posthogApiKey;

  String? get apiBaseUrl;

  String? get googleMapsApiKey;

  String? get intercomAppId;

  String? get intercomIOSApiKey;

  String? get intercomAndroidApiKey;

  String? get googleClientId;

  String? get googleClientSecret;

  bool? get useWebAuth;

  bool? get useAuthCustomToken;
}
