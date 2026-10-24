import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Device keychain / keystore storage for secrets. Fails with
/// [SecretStoreException] instead of losing what it holds.
abstract interface class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// The keychain / keystore could not be read or written. The saved PIN may
/// still be there, so this must never count as "no PIN".
class SecretStoreException implements Exception {
  const SecretStoreException(this.cause);

  final Object cause;

  @override
  String toString() => 'SecretStoreException: $cause';
}

/// Fingerprint / Face ID. Both methods return false instead of throwing.
abstract interface class BiometricAuth {
  Future<bool> isAvailable();
  Future<bool> authenticate(String reason);
}

/// Hides the app from screenshots and the recent-apps preview.
abstract interface class ScreenPrivacy {
  Future<void> setSecure(bool secure);
}

/// What the app lock asks for: digits on a pad, or any text on the keyboard.
enum SecretKind { pin, password }

const minPasswordLength = 4;

bool isValidPin(String pin) => RegExp(r'^\d{4,8}$').hasMatch(pin);

bool isValidPassword(String password) => password.length >= minPasswordLength;

/// Wrong tries allowed before the lock makes the user wait.
const freeTries = 5;

const _waits = [
  Duration(minutes: 5),
  Duration(minutes: 30),
  Duration(hours: 1),
  Duration(hours: 2),
  Duration(hours: 4),
  Duration(hours: 8),
];

/// How long to wait after [wrongTries] wrong tries in a row: nothing for the
/// first few, then 5 minutes, and longer after each further wrong try, up to
/// 8 hours. A 4-digit PIN would otherwise fall to trying all 10,000.
Duration? waitAfter(int wrongTries) =>
    wrongTries < freeTries ? null : _waits[min(wrongTries - freeTries, _waits.length - 1)];

/// The outcome of one unlock try.
class UnlockResult {
  const UnlockResult({required this.ok, this.waitUntil, this.triesLeft = 0, this.unreadable = false});

  /// The secret could not be checked because the keystore failed; the try
  /// was not counted.
  const UnlockResult.unreadable() : this(ok: false, unreadable: true);

  final bool ok;
  final bool unreadable;

  /// Set while tries are paused. A try made before then is not checked.
  final DateTime? waitUntil;

  /// Wrong tries left before the next pause.
  final int triesLeft;
}

/// Whether the app opens locked, and with a PIN pad or a password field.
class LockStart {
  const LockStart({required this.locked, this.kind});

  static const open = LockStart(locked: false);

  final bool locked;

  /// Null when the keystore could not be read: the lock screen then takes
  /// either a PIN or a password.
  final SecretKind? kind;

  /// With the lock turned on, a keystore that fails to read keeps the app
  /// locked: opening it would hand the data to whoever holds the phone. Only
  /// a keystore that reads fine and holds no PIN opens it, as after a
  /// reinstall or a restore from another phone.
  static Future<LockStart> read({required bool lockEnabled, required PinVault vault}) async {
    if (!lockEnabled) return open;
    try {
      final kind = await vault.kind();
      return kind == null ? open : LockStart(locked: true, kind: kind);
    } on SecretStoreException {
      return const LockStart(locked: true);
    }
  }
}

/// The app was away (backgrounded) since [awaySince]; it relocks once it was
/// away for at least the timeout. Short trips (notification shade, a phone
/// call under the timeout) do not relock.
bool shouldLockOnReturn({required DateTime? awaySince, required DateTime now, required int timeoutSeconds}) =>
    awaySince != null && now.difference(awaySince).inSeconds >= timeoutSeconds;

/// Keeps only a salted PBKDF2-SHA256 hash of the PIN or password, never the
/// secret itself, and counts wrong tries in the same secure storage so a
/// restart does not reset them.
class PinVault {
  PinVault(this._store, {this.iterations = 60000, Random? random}) : _random = random ?? Random.secure();

  static const _key = 'app_pin';
  static const _triesKey = 'app_pin_tries';

  final SecretStore _store;
  final int iterations;
  final Random _random;

  Future<bool> hasPin() async => await _store.read(_key) != null;

  Future<void> setPin(String pin) => setSecret(pin, SecretKind.pin);

  Future<void> setSecret(String secret, SecretKind kind) async {
    final salt = List<int>.generate(16, (_) => _random.nextInt(256));
    final hash = pbkdf2Sha256(utf8.encode(secret), salt, iterations, 32);
    await _store.write(
      _key,
      'pbkdf2-sha256\$$iterations\$${base64.encode(salt)}\$${base64.encode(hash)}\$${kind.name}',
    );
    await _store.delete(_triesKey);
  }

  /// Null when no secret is saved. A PIN saved before passwords existed has
  /// no kind and is a PIN.
  Future<SecretKind?> kind() async {
    final parts = (await _store.read(_key))?.split(r'$');
    if (parts == null) return null;
    return parts.length > 4 ? SecretKind.values.byName(parts[4]) : SecretKind.pin;
  }

  /// One counted try: the lock screen and every check in Settings go through
  /// here, so they share the same count and pause.
  Future<UnlockResult> attempt(String secret, DateTime now) async {
    final (wrong, until) = await _tries();
    if (until != null && now.isBefore(until)) return UnlockResult(ok: false, waitUntil: until);
    if (await verify(secret)) {
      await _store.delete(_triesKey);
      return const UnlockResult(ok: true);
    }
    final tries = wrong + 1;
    final wait = waitAfter(tries);
    final next = wait == null ? null : now.add(wait);
    await _store.write(_triesKey, '$tries,${next?.millisecondsSinceEpoch ?? ''}');
    return UnlockResult(ok: false, waitUntil: next, triesLeft: max(0, freeTries - tries));
  }

  /// Fingerprint or face unlock proves it is the owner, so the count starts over.
  Future<void> forgetWrongTries() => _store.delete(_triesKey);

  Future<(int, DateTime?)> _tries() async {
    final stored = await _store.read(_triesKey);
    if (stored == null) return (0, null);
    final [count, until] = stored.split(',');
    return (int.parse(count), until.isEmpty ? null : DateTime.fromMillisecondsSinceEpoch(int.parse(until)));
  }

  /// Checks the secret without counting the try. The app must use [attempt].
  Future<bool> verify(String secret) async {
    final stored = await _store.read(_key);
    if (stored == null) return false;
    final [_, rounds, salt, hash, ...] = stored.split(r'$');
    final expected = base64.decode(hash);
    final actual = pbkdf2Sha256(utf8.encode(secret), base64.decode(salt), int.parse(rounds), expected.length);
    var diff = 0;
    for (var i = 0; i < expected.length; i++) {
      diff |= expected[i] ^ actual[i];
    }
    return diff == 0;
  }

  Future<void> clear() async {
    await _store.delete(_key);
    await _store.delete(_triesKey);
  }
}

List<int> pbkdf2Sha256(List<int> password, List<int> salt, int iterations, int length) {
  final hmac = Hmac(sha256, password);
  final out = BytesBuilder();
  for (var block = 1; out.length < length; block++) {
    var u = hmac.convert([...salt, block >> 24 & 0xff, block >> 16 & 0xff, block >> 8 & 0xff, block & 0xff]).bytes;
    final t = List<int>.of(u);
    for (var i = 1; i < iterations; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < t.length; j++) {
        t[j] ^= u[j];
      }
    }
    out.add(t);
  }
  return out.toBytes().sublist(0, length);
}
