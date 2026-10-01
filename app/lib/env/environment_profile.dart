/// The supported mobile trust/data planes.
///
/// A profile is intentionally selected at build time. The default for the
/// `dev` flavor is local emulators; access to production Firebase identity and
/// data requires the explicit `mobile_beta` profile.
enum AppEnvironmentProfile {
  localDev(
    name: 'local_dev',
    defaultApiBaseUrl: 'http://127.0.0.1:8000/',
    firebaseProjectId: 'demo-omi-local',
    authCallbackScheme: 'omi-dev',
    usesFirebaseAuthEmulator: true,
    allowsProductionData: false,
  ),
  mobileBeta(
    name: 'mobile_beta',
    defaultApiBaseUrl: 'https://api.omiapi.com/',
    firebaseProjectId: 'based-hardware',
    authCallbackScheme: 'omi-beta',
    usesFirebaseAuthEmulator: false,
    allowsProductionData: true,
  ),
  production(
    name: 'production',
    defaultApiBaseUrl: 'https://api.omi.me/',
    firebaseProjectId: 'based-hardware',
    authCallbackScheme: 'omi',
    usesFirebaseAuthEmulator: false,
    allowsProductionData: true,
  ),

  /// Self-hosted personal build: the `cason-omi` Firebase project paired with
  /// a backend that trusts it. There is intentionally no default host; the
  /// serving API must be supplied at build time via
  /// `--dart-define=OMI_API_BASE_URL=...` or `API_BASE_URL` in `.env`, and
  /// startup validation fails loudly when it is missing.
  personal(
    name: 'personal',
    defaultApiBaseUrl: '',
    firebaseProjectId: 'cason-omi',
    authCallbackScheme: 'omi',
    usesFirebaseAuthEmulator: false,
    allowsProductionData: true,
  );

  const AppEnvironmentProfile({
    required this.name,
    required this.defaultApiBaseUrl,
    required this.firebaseProjectId,
    required this.authCallbackScheme,
    required this.usesFirebaseAuthEmulator,
    required this.allowsProductionData,
  });

  final String name;
  final String defaultApiBaseUrl;
  final String firebaseProjectId;
  final String authCallbackScheme;
  final bool usesFirebaseAuthEmulator;
  final bool allowsProductionData;

  /// True when the profile has no built-in serving API and the build must
  /// provide one explicitly (never falls back to a Based Hardware host).
  bool get requiresExplicitApiBaseUrl => defaultApiBaseUrl.isEmpty;

  static AppEnvironmentProfile forFlavor({required bool productionFlavor}) {
    const requested = String.fromEnvironment('OMI_APP_PROFILE');
    if (requested.isEmpty) {
      return productionFlavor ? AppEnvironmentProfile.production : AppEnvironmentProfile.localDev;
    }

    return AppEnvironmentProfile.values.firstWhere(
      (profile) => profile.name == requested,
      orElse: () => throw StateError(
        'Unknown OMI_APP_PROFILE "$requested". '
        'Use local_dev, mobile_beta, production, or personal.',
      ),
    );
  }
}
