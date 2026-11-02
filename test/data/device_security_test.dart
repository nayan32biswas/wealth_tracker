import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth_platform_interface/local_auth_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:wealthtracker/data/device_security.dart';
import 'package:wealthtracker/domain/services/security.dart';

const _channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <MethodCall>[];
  void answer(Object? Function(MethodCall call) reply) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      return reply(call);
    });
  }

  setUp(calls.clear);
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null),
  );

  test('asks Android not to wipe the saved PIN after a failed read', () async {
    answer((_) => 'stored');

    expect(await KeychainSecretStore().read('app_pin'), 'stored');

    final options = (calls.single.arguments as Map)['options'] as Map;
    expect(options['resetOnError'], 'false');
  });

  test('a failed read is reported, not taken as "no PIN"', () async {
    answer((_) => throw PlatformException(code: 'Exception encountered', message: 'bad key'));

    await expectLater(KeychainSecretStore().read('app_pin'), throwsA(isA<SecretStoreException>()));
  });

  test('saves and removes a secret under its key', () async {
    answer((_) => null);

    await KeychainSecretStore().write('app_pin', '1234');
    await KeychainSecretStore().delete('app_pin');

    expect(calls.map((c) => c.method), ['write', 'delete']);
    expect((calls[0].arguments as Map)['key'], 'app_pin');
    expect((calls[0].arguments as Map)['value'], '1234');
    expect((calls[1].arguments as Map)['key'], 'app_pin');
  });

  test('a failed save or remove is reported', () async {
    answer((_) => throw PlatformException(code: 'Exception encountered'));

    await expectLater(KeychainSecretStore().write('app_pin', '1234'), throwsA(isA<SecretStoreException>()));
    await expectLater(KeychainSecretStore().delete('app_pin'), throwsA(isA<SecretStoreException>()));
  });

  group('fingerprint and face', () {
    late _FakeAuth auth;
    final original = LocalAuthPlatform.instance;

    setUp(() => LocalAuthPlatform.instance = auth = _FakeAuth());
    tearDown(() => LocalAuthPlatform.instance = original);

    test('are offered only when the phone supports them and can check them', () async {
      expect(await DeviceBiometrics().isAvailable(), isTrue);

      auth.biometrics = false;
      expect(await DeviceBiometrics().isAvailable(), isFalse);

      auth
        ..biometrics = true
        ..supported = false;
      expect(await DeviceBiometrics().isAvailable(), isFalse);
    });

    test('a phone that fails to answer counts as not supported', () async {
      auth.fail = true;

      expect(await DeviceBiometrics().isAvailable(), isFalse);
    });

    test('unlock asks for a fingerprint or face only, never the phone PIN, with the reason shown', () async {
      expect(await DeviceBiometrics().authenticate('Unlock WealthTracker'), isTrue);

      expect(auth.reason, 'Unlock WealthTracker');
      expect(auth.biometricOnly, isTrue);

      auth.accept = false;
      expect(await DeviceBiometrics().authenticate('Unlock WealthTracker'), isFalse);
    });

    test('an error while checking counts as a failed unlock', () async {
      auth.fail = true;

      expect(await DeviceBiometrics().authenticate('Unlock WealthTracker'), isFalse);
    });
  });

  test('blocking screenshots asks nothing of the phone outside Android', () async {
    const privacy = MethodChannel('wealthtracker/privacy');
    final sent = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(privacy, (call) async {
      sent.add(call);
      return null;
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(privacy, null),
    );

    await NativeScreenPrivacy().setSecure(true);

    expect(sent, Platform.isAndroid ? hasLength(1) : isEmpty);
  });
}

class _FakeAuth extends LocalAuthPlatform with MockPlatformInterfaceMixin {
  bool supported = true;
  bool biometrics = true;
  bool accept = true;
  bool fail = false;
  String? reason;
  bool? biometricOnly;

  void _maybeFail() {
    if (fail) throw PlatformException(code: 'NotAvailable');
  }

  @override
  Future<bool> isDeviceSupported() async {
    _maybeFail();
    return supported;
  }

  @override
  Future<bool> deviceSupportsBiometrics() async {
    _maybeFail();
    return biometrics;
  }

  @override
  Future<bool> authenticate({
    required String localizedReason,
    required Iterable<AuthMessages> authMessages,
    AuthenticationOptions options = const AuthenticationOptions(),
  }) async {
    _maybeFail();
    reason = localizedReason;
    biometricOnly = options.biometricOnly;
    return accept;
  }
}
