import 'package:flutter_test/flutter_test.dart';
import 'package:omi/env/env.dart';
import 'package:omi/env/environment_profile.dart';
import 'package:omi/flavors.dart';
import 'package:omi/startup_routing.dart';
import 'dart:io';

/// Minimal EnvFields stub for testing Env logic in isolation.
/// Since Env._instance is late final (can only be set once per process),
/// we test with a single init and exercise the override/flag mechanisms.
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
  // Init once for the entire test suite (late final constraint)
  setUpAll(() {
    Env.init(_TestEnvFields());
  });

  group('Env.isTestFlight', () {
    test('can be set to false', () {
      Env.isTestFlight = false;
      expect(Env.isTestFlight, isFalse);
    });

    test('can be set to true', () {
      Env.isTestFlight = true;
      expect(Env.isTestFlight, isTrue);
      // Clean up
      Env.isTestFlight = false;
    });
  });

  group('mobile environment profiles', () {
    test('local development is emulator-first and does not allow production data', () {
      expect(AppEnvironmentProfile.localDev.defaultApiBaseUrl, 'http://127.0.0.1:8000/');
      expect(AppEnvironmentProfile.localDev.firebaseProjectId, 'demo-omi-local');
      expect(AppEnvironmentProfile.localDev.usesFirebaseAuthEmulator, isTrue);
      expect(AppEnvironmentProfile.localDev.allowsProductionData, isFalse);
    });

    test('mobile beta explicitly pairs production Firebase with the dev serving plane', () {
      expect(AppEnvironmentProfile.mobileBeta.defaultApiBaseUrl, 'https://api.omiapi.com/');
      expect(AppEnvironmentProfile.mobileBeta.firebaseProjectId, 'based-hardware');
      expect(AppEnvironmentProfile.mobileBeta.usesFirebaseAuthEmulator, isFalse);
      expect(AppEnvironmentProfile.mobileBeta.allowsProductionData, isTrue);
      expect(AppEnvironmentProfile.mobileBeta.authCallbackScheme, 'omi-beta');
    });

    test('mobile beta keeps OAuth on the production identity plane', () {
      expect(
        Env.authApiBaseUrlForProfile(
          AppEnvironmentProfile.mobileBeta,
          servingApiBaseUrl: 'https://api.omiapi.com/',
        ),
        Env.productionApiBaseUrl,
      );
    });

    test('local profile rejects a production Firebase project', () {
      expect(
        () => Env.validateFirebaseProject(
          projectId: 'based-hardware',
          configuredProfile: AppEnvironmentProfile.localDev,
        ),
        throwsStateError,
      );
    });

    test('the profile set is pinned', () {
      expect(
        AppEnvironmentProfile.values.map((profile) => profile.name).toList(),
        ['local_dev', 'mobile_beta', 'production', 'personal'],
      );
      for (final profile in [
        AppEnvironmentProfile.localDev,
        AppEnvironmentProfile.mobileBeta,
        AppEnvironmentProfile.production,
      ]) {
        expect(profile.requiresExplicitApiBaseUrl, isFalse, reason: profile.name);
      }
    });

    test('flavor defaults map to production and local profiles', () {
      expect(
        AppEnvironmentProfile.forFlavor(productionFlavor: true),
        AppEnvironmentProfile.production,
      );
      expect(
        AppEnvironmentProfile.forFlavor(productionFlavor: false),
        AppEnvironmentProfile.localDev,
      );
    });
  });

  group('Env.apiBaseUrl', () {
    test('uses the local emulator API when development env has no URL', () {
      expect(Env.apiBaseUrl, 'http://127.0.0.1:8000/');
    });

    test('returns override when set', () {
      Env.overrideApiBaseUrl('https://override.example.com/');
      expect(Env.apiBaseUrl, 'https://override.example.com/');
      Env.clearApiBaseUrlOverrideForTesting();
    });

    test('TestFlight production startup accepts the production API and WebSocket', () {
      validateApplicationStartupRouting(environment: Environment.prod, configuredApiBaseUrl: 'https://api.omi.me/');
      expect(Env.productionAgentProxyWsUrl, 'wss://agent.omi.me/v1/agent/ws');
    });

    test('Android production startup accepts the production API and WebSocket', () {
      validateApplicationStartupRouting(environment: Environment.prod, configuredApiBaseUrl: 'https://api.omi.me/');
      expect(Env.productionAgentProxyWsUrl, 'wss://agent.omi.me/v1/agent/ws');
    });

    test('mobile beta accepts the dev serving plane with production identity', () {
      Env.validateStartupRouting(
        productionFamily: true,
        configuredProfile: AppEnvironmentProfile.mobileBeta,
        configuredApiBaseUrl: 'https://api.omiapi.com/',
      );
    });

    test('production startup rejects legacy Beta, dev, staging, and arbitrary endpoints', () {
      for (final endpoint in [
        'https://api-beta.omi.me/',
        'https://api.omi.dev/',
        'https://staging.example.test/',
        'https://arbitrary.example.test/',
      ]) {
        expect(
          () => validateApplicationStartupRouting(environment: Environment.prod, configuredApiBaseUrl: endpoint),
          throwsStateError,
          reason: endpoint,
        );
      }
    });

    test('local development startup accepts the emulator API', () {
      expect(
        () => validateApplicationStartupRouting(
          environment: Environment.dev,
          configuredApiBaseUrl: 'http://127.0.0.1:8000/',
        ),
        returnsNormally,
      );
    });

    test('local development rejects the remote dev serving plane', () {
      expect(
        () => validateApplicationStartupRouting(
          environment: Environment.dev,
          configuredApiBaseUrl: 'https://api.omiapi.com/',
        ),
        throwsStateError,
      );
    });
  });

  group('personal profile', () {
    const personal = AppEnvironmentProfile.personal;
    const tailnetUrl = 'https://omi.taileb7e4.ts.net/';

    test('pairs the cason-omi Firebase project with a build-provided API host', () {
      expect(personal.name, 'personal');
      expect(personal.firebaseProjectId, 'cason-omi');
      expect(personal.authCallbackScheme, 'omi');
      expect(personal.usesFirebaseAuthEmulator, isFalse);
      expect(personal.defaultApiBaseUrl, isEmpty);
      expect(personal.requiresExplicitApiBaseUrl, isTrue);
    });

    test('profile pairing requires the prod flavor', () {
      expect(
        () => Env.validateProfilePairing(productionFlavor: true, configuredProfile: personal),
        returnsNormally,
      );
      expect(
        () => Env.validateProfilePairing(productionFlavor: false, configuredProfile: personal),
        throwsStateError,
      );
    });

    test('profile pairing is unchanged for the existing profiles', () {
      expect(
        () => Env.validateProfilePairing(
          productionFlavor: true,
          configuredProfile: AppEnvironmentProfile.production,
        ),
        returnsNormally,
      );
      expect(
        () => Env.validateProfilePairing(
          productionFlavor: true,
          configuredProfile: AppEnvironmentProfile.mobileBeta,
        ),
        returnsNormally,
      );
      expect(
        () => Env.validateProfilePairing(
          productionFlavor: false,
          configuredProfile: AppEnvironmentProfile.localDev,
        ),
        returnsNormally,
      );
      expect(
        () => Env.validateProfilePairing(
          productionFlavor: true,
          configuredProfile: AppEnvironmentProfile.localDev,
        ),
        throwsStateError,
      );
      expect(
        () => Env.validateProfilePairing(
          productionFlavor: false,
          configuredProfile: AppEnvironmentProfile.production,
        ),
        throwsStateError,
      );
    });

    test('accepts only the cason-omi Firebase project', () {
      expect(
        () => Env.validateFirebaseProject(projectId: 'cason-omi', configuredProfile: personal),
        returnsNormally,
      );
      expect(
        () => Env.validateFirebaseProject(projectId: 'based-hardware', configuredProfile: personal),
        throwsStateError,
      );
      expect(
        () => Env.validateFirebaseProject(
          projectId: 'cason-omi',
          configuredProfile: AppEnvironmentProfile.production,
        ),
        throwsStateError,
      );
    });

    test('startup routing accepts the provided self-hosted API', () {
      for (final endpoint in [
        tailnetUrl,
        'https://omi.taileb7e4.ts.net',
        'http://100.101.102.103:8000/',
        'https://api.example.com:8443/',
      ]) {
        expect(
          () => Env.validateStartupRouting(
            productionFamily: true,
            configuredProfile: personal,
            configuredApiBaseUrl: endpoint,
          ),
          returnsNormally,
          reason: endpoint,
        );
      }
    });

    test('startup routing fails clearly when no API host is provided', () {
      expect(
        () => Env.validateStartupRouting(
          productionFamily: true,
          configuredProfile: personal,
          configuredApiBaseUrl: '',
        ),
        throwsA(
          isA<StateError>().having((e) => e.message, 'message', contains('--dart-define=OMI_API_BASE_URL')),
        ),
      );
    });

    test('startup routing rejects malformed and Based Hardware hosts', () {
      for (final endpoint in [
        'not a url',
        'ftp://files.example.com/',
        '/relative/path/',
        'https://api.omi.me/',
        'https://API.OMI.ME',
        'https://api.omiapi.com/',
      ]) {
        expect(
          () => Env.validateStartupRouting(
            productionFamily: true,
            configuredProfile: personal,
            configuredApiBaseUrl: endpoint,
          ),
          throwsStateError,
          reason: endpoint,
        );
      }
    });

    test('OAuth uses the self-hosted serving API', () {
      expect(Env.authApiBaseUrlForProfile(personal, servingApiBaseUrl: tailnetUrl), tailnetUrl);
    });

    test('agent WebSocket derivation never throws for arbitrary hosts', () {
      expect(Env.selfHostedAgentProxyWsUrlFor(tailnetUrl), 'wss://omi.taileb7e4.ts.net/v1/agent/ws');
      expect(Env.selfHostedAgentProxyWsUrlFor('http://100.101.102.103:8000/'), 'ws://100.101.102.103:8000/v1/agent/ws');
      expect(Env.selfHostedAgentProxyWsUrlFor('https://api.example.com/'), 'wss://api.example.com/v1/agent/ws');
      expect(Env.selfHostedAgentProxyWsUrlFor('http://[::1]:8000/'), 'ws://[::1]:8000/v1/agent/ws');
      for (final garbage in ['', 'not a url', 'http://', '::::', 'https://exa mple.com/']) {
        expect(() => Env.selfHostedAgentProxyWsUrlFor(garbage), returnsNormally, reason: garbage);
      }
    });
  });

  test('main invokes the production startup routing seam before services initialize', () {
    // Static wiring tripwire: the behavioral cases above call the exact seam.
    final mainSource = File('lib/main.dart').readAsStringSync();
    expect(mainSource, contains('validateApplicationStartupRouting();'));
    expect(
      mainSource.indexOf('validateApplicationStartupRouting();'),
      lessThan(mainSource.indexOf('ServiceManager.init()')),
    );
    expect(
      mainSource,
      contains('Env.validateFirebaseProject(projectId: Firebase.app().options.projectId);'),
    );
  });

  test('main surfaces startup failures instead of stalling on the launch screen', () {
    final mainSource = File('lib/main.dart').readAsStringSync();
    expect(mainSource, contains('runApp(StartupErrorApp(error: error, stackTrace: stack));'));
    // Crashlytics must not be reached before Firebase has a default app.
    expect(mainSource, contains('if (Firebase.apps.isEmpty) return;'));
    expect(mainSource, isNot(contains('(error, stack) => FirebaseCrashlytics.instance.recordError(')));
  });
}
