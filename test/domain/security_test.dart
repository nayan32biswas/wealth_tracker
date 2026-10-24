import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wealthtracker/domain/models/app_settings.dart';
import 'package:wealthtracker/domain/services/security.dart';

class MemoryStore implements SecretStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// A keystore that fails, like Android's after a bad key or a broken update.
class BrokenStore implements SecretStore {
  @override
  Future<String?> read(String key) async => throw const SecretStoreException('bad key');

  @override
  Future<void> write(String key, String value) async => throw const SecretStoreException('bad key');

  @override
  Future<void> delete(String key) async => throw const SecretStoreException('bad key');
}

String hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('pbkdf2', () {
    test('matches the published SHA-256 test vector', () {
      expect(
        hex(pbkdf2Sha256(utf8.encode('password'), utf8.encode('salt'), 1, 32)),
        '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b',
      );
      expect(
        hex(pbkdf2Sha256(utf8.encode('password'), utf8.encode('salt'), 2, 32)),
        'ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43',
      );
    });
  });

  group('PIN vault', () {
    test('stores only a salted hash and verifies the PIN', () async {
      final store = MemoryStore();
      final vault = PinVault(store, iterations: 10);

      await vault.setPin('1234');

      expect(await vault.hasPin(), isTrue);
      expect(store.values.values.single, isNot(contains('1234')));
      expect(await vault.verify('1234'), isTrue);
      expect(await vault.verify('4321'), isFalse);
    });

    test('the same PIN hashes differently each time', () async {
      final a = MemoryStore();
      final b = MemoryStore();
      await PinVault(a, iterations: 10).setPin('1234');
      await PinVault(b, iterations: 10).setPin('1234');

      expect(a.values.values.single, isNot(b.values.values.single));
    });

    test('clearing removes the PIN', () async {
      final vault = PinVault(MemoryStore(), iterations: 10);
      await vault.setPin('1234');
      await vault.clear();

      expect(await vault.hasPin(), isFalse);
      expect(await vault.verify('1234'), isFalse);
    });

    test('PINs are 4 to 8 digits', () {
      expect(isValidPin('123'), isFalse);
      expect(isValidPin('1234'), isTrue);
      expect(isValidPin('12345678'), isTrue);
      expect(isValidPin('123456789'), isFalse);
      expect(isValidPin('12a4'), isFalse);
    });
  });

  group('passwords', () {
    test('a password of any characters is kept and checked like a PIN', () async {
      final vault = PinVault(MemoryStore(), iterations: 10);
      await vault.setSecret('ভাত & dal 9!', SecretKind.password);

      expect(await vault.kind(), SecretKind.password);
      expect(await vault.verify('ভাত & dal 9!'), isTrue);
      expect(await vault.verify('ভাত & dal 9'), isFalse);
    });

    test('a PIN saved before passwords existed is still a PIN', () async {
      final store = MemoryStore();
      final vault = PinVault(store, iterations: 10);
      await vault.setPin('1234');
      store.values['app_pin'] = store.values['app_pin']!.substring(0, store.values['app_pin']!.lastIndexOf(r'$'));

      expect(await vault.kind(), SecretKind.pin);
      expect(await vault.verify('1234'), isTrue);
    });

    test('passwords need at least 4 characters', () {
      expect(isValidPassword('abc'), isFalse);
      expect(isValidPassword('ab c'), isTrue);
    });
  });

  group('wrong tries', () {
    final now = DateTime(2026, 10, 3, 9);

    test('5 wrong tries are free, then the wait grows to 8 hours', () {
      expect([for (var n = 1; n <= 4; n++) waitAfter(n)], everyElement(isNull));
      expect(
        [for (var n = 5; n <= 11; n++) waitAfter(n)],
        const [
          Duration(minutes: 5),
          Duration(minutes: 30),
          Duration(hours: 1),
          Duration(hours: 2),
          Duration(hours: 4),
          Duration(hours: 8),
          Duration(hours: 8),
        ],
      );
    });

    test('the 5th wrong try pauses tries, and even the right PIN waits', () async {
      final vault = PinVault(MemoryStore(), iterations: 10);
      await vault.setPin('1234');

      final lefts = [for (var i = 0; i < 4; i++) (await vault.attempt('0000', now)).triesLeft];
      final fifth = await vault.attempt('0000', now);
      final during = await vault.attempt('1234', now.add(const Duration(minutes: 4)));

      expect(lefts, [4, 3, 2, 1]);
      expect(fifth.waitUntil, now.add(const Duration(minutes: 5)));
      expect(during.ok, isFalse);
      expect(during.waitUntil, now.add(const Duration(minutes: 5)));
    });

    test('a wrong try after the wait pauses longer; the right one starts the count over', () async {
      final vault = PinVault(MemoryStore(), iterations: 10);
      await vault.setPin('1234');
      for (var i = 0; i < 5; i++) {
        await vault.attempt('0000', now);
      }
      final later = now.add(const Duration(minutes: 5));

      expect((await vault.attempt('0000', later)).waitUntil, later.add(const Duration(minutes: 30)));
      final after = later.add(const Duration(minutes: 30));
      expect((await vault.attempt('1234', after)).ok, isTrue);
      expect((await vault.attempt('0000', after)).triesLeft, 4);
    });

    test('the count survives a restart and a clock set back', () async {
      final store = MemoryStore();
      await PinVault(store, iterations: 10).setPin('1234');
      for (var i = 0; i < 5; i++) {
        await PinVault(store, iterations: 10).attempt('0000', now);
      }

      final restarted = PinVault(store, iterations: 10);
      final backInTime = await restarted.attempt('1234', now.subtract(const Duration(hours: 1)));

      expect(backInTime.ok, isFalse);
    });

    test('a new PIN starts the count over', () async {
      final vault = PinVault(MemoryStore(), iterations: 10);
      await vault.setPin('1234');
      for (var i = 0; i < 5; i++) {
        await vault.attempt('0000', now);
      }
      await vault.setPin('5678');

      expect((await vault.attempt('5678', now)).ok, isTrue);
    });
  });

  group('lock timing', () {
    final away = DateTime(2026, 9, 23, 10);

    test('locks once the app was away at least the timeout', () {
      expect(
        shouldLockOnReturn(awaySince: away, now: away.add(const Duration(seconds: 60)), timeoutSeconds: 60),
        isTrue,
      );
      expect(
        shouldLockOnReturn(awaySince: away, now: away.add(const Duration(seconds: 59)), timeoutSeconds: 60),
        isFalse,
      );
    });

    test('a zero timeout locks immediately', () {
      expect(shouldLockOnReturn(awaySince: away, now: away, timeoutSeconds: 0), isTrue);
    });

    test('never locks when the app did not go away', () {
      expect(shouldLockOnReturn(awaySince: null, now: away, timeoutSeconds: 0), isFalse);
    });

    test('lock after defaults to 10 seconds and never goes past 60', () {
      expect(AppSettings.fromMap({}).lockTimeoutSeconds, 10);
      expect(AppSettings.fromMap({'lock_timeout_seconds': '300'}).lockTimeoutSeconds, 60);
      expect(AppSettings.fromMap({'lock_timeout_seconds': '-5'}).lockTimeoutSeconds, 0);
    });
  });

  group('locked at start', () {
    test('a saved password opens the password field', () async {
      final vault = PinVault(MemoryStore(), iterations: 10);
      await vault.setSecret('open sesame', SecretKind.password);

      final start = await LockStart.read(lockEnabled: true, vault: vault);

      expect((start.locked, start.kind), (true, SecretKind.password));
    });

    test('a keystore that cannot be read keeps the app locked', () async {
      final start = await LockStart.read(lockEnabled: true, vault: PinVault(BrokenStore(), iterations: 10));

      expect((start.locked, start.kind), (true, null));
    });

    test('no saved PIN opens the app, as after a restore from another phone', () async {
      final start = await LockStart.read(lockEnabled: true, vault: PinVault(MemoryStore(), iterations: 10));

      expect(start.locked, isFalse);
    });

    test('the lock turned off opens the app without reading the keystore', () async {
      final start = await LockStart.read(lockEnabled: false, vault: PinVault(BrokenStore(), iterations: 10));

      expect(start.locked, isFalse);
    });
  });
}
