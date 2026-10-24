import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
