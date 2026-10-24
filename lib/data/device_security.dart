import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

import '../domain/services/security.dart';

class KeychainSecretStore implements SecretStore {
  /// The plugin's default wipes every saved secret after one failed read,
  /// which would delete the PIN and quietly turn the lock off.
  static const androidOptions = AndroidOptions(resetOnError: false);

  static const _storage = FlutterSecureStorage(aOptions: androidOptions);

  @override
  Future<String?> read(String key) => _guard(() => _storage.read(key: key));

  @override
  Future<void> write(String key, String value) => _guard(() => _storage.write(key: key, value: value));

  @override
  Future<void> delete(String key) => _guard(() => _storage.delete(key: key));

  static Future<T> _guard<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on PlatformException catch (e) {
      throw SecretStoreException(e);
    }
  }
}

class DeviceBiometrics implements BiometricAuth {
  final _auth = LocalAuthentication();

  @override
  Future<bool> isAvailable() async {
    try {
      return await _auth.isDeviceSupported() && await _auth.canCheckBiometrics;
    } on Exception {
      return false;
    }
  }

  @override
  Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(localizedReason: reason, biometricOnly: true);
    } on Exception {
      return false;
    }
  }
}

/// Android only: FLAG_SECURE blanks the recent-apps preview and blocks
/// screenshots. iOS relies on the in-app privacy cover instead.
class NativeScreenPrivacy implements ScreenPrivacy {
  static const _channel = MethodChannel('wealthtracker/privacy');

  @override
  Future<void> setSecure(bool secure) async {
    if (Platform.isAndroid) await _channel.invokeMethod<void>('setSecure', secure);
  }
}
