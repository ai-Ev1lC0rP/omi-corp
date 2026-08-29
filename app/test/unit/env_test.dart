import 'package:flutter_test/flutter_test.dart';
import 'package:omi/env/env.dart';
import 'package:omi/env/environment_profile.dart';
import 'package:omi/flavors.dart';
import 'package:omi/firebase_options_local.dart' as local_firebase;
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
    test('local iOS Firebase options use an SDK-valid application id', () {
      expect(
        local_firebase.DefaultFirebaseOptions.ios.appId,
        matches(RegExp(r'^1:[0-9]{12}:ios:[0-9a-f]{32}$')),
      );
    });

    test('local iOS Firebase options use an SDK-valid API key shape', () {
      expect(
        local_firebase.DefaultFirebaseOptions.ios.apiKey,
        matches(RegExp(r'^A[A-Za-z0-9_-]{38}$')),
      );
    });

    test('local development is emulator-first and does not allow production data', () {
      expect(AppEnvironmentProfile.localDev.defaultApiBaseUrl, 'http://127.0.0.1:8000/');
      expect(AppEnvironmentProfile.localDev.firebaseProjectId, 'demo-omi-local');
      expect(AppEnvironmentProfile.localDev.usesFirebaseAuthEmulator, isTrue);
      expect(AppEnvironmentProfile.localDev.allowsProductionData, isFalse);
    });

    test('self-hosted development uses the cason Firebase identity with a local API', () {
      expect(AppEnvironmentProfile.selfHosted.defaultApiBaseUrl, 'http://127.0.0.1:8000/');
      expect(AppEnvironmentProfile.selfHosted.firebaseProjectId, 'cason-omi');
      expect(AppEnvironmentProfile.selfHosted.usesFirebaseAuthEmulator, isFalse);
      expect(AppEnvironmentProfile.selfHosted.allowsProductionData, isTrue);
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

    test('self-hosted profile accepts only the cason Firebase project', () {
      expect(
        () => Env.validateFirebaseProject(
          projectId: 'cason-omi',
          configuredProfile: AppEnvironmentProfile.selfHosted,
        ),
        returnsNormally,
      );
      expect(
        () => Env.validateFirebaseProject(
          projectId: 'based-hardware',
          configuredProfile: AppEnvironmentProfile.selfHosted,
        ),
        throwsStateError,
      );
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

    test('self-hosted development accepts a secure public reverse proxy', () {
      expect(
        () => Env.validateStartupRouting(
          productionFamily: false,
          configuredProfile: AppEnvironmentProfile.selfHosted,
          configuredApiBaseUrl: 'https://omi-api.casonclark.com/',
        ),
        returnsNormally,
      );
    });

    test('self-hosted development rejects an insecure public endpoint', () {
      expect(
        () => Env.validateStartupRouting(
          productionFamily: false,
          configuredProfile: AppEnvironmentProfile.selfHosted,
          configuredApiBaseUrl: 'http://public.example.test/',
        ),
        throwsStateError,
      );
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
}
