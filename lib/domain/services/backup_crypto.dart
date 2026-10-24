import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/gcm.dart';

import '../repositories/repositories.dart';
import 'security.dart';

/// Runs slow work somewhere else. The app uses a background isolate so key
/// derivation does not freeze the screen; tests run it inline.
typedef Offload = Future<R> Function<R>(FutureOr<R> Function() work);

class WrongBackupPassword extends RuleViolation {
  const WrongBackupPassword() : super('Wrong password, or the file is damaged.');
}

// File layout: magic(8) salt(16) nonce(12), then AES-256-GCM ciphertext with
// its 16-byte tag. The header is authenticated too, so a changed salt is caught.
final _magic = ascii.encode('WTBACKUP');
const _saltLength = 16;
const _nonceLength = 12;
const _headerLength = 8 + _saltLength + _nonceLength;
const _tagLength = 16;

/// Password protection for backup files. The salt is stored in the file, so
/// any phone with the app can open it with the password alone.
class BackupCipher {
  BackupCipher({this.iterations = 600000, Random? random, Offload? offload})
    : _random = random ?? Random.secure(),
      _offload = offload ?? Isolate.run;

  /// PBKDF2-SHA256 rounds. A backup leaves the phone, so it gets the OWASP
  /// count rather than the PIN's lower one.
  final int iterations;
  final Random _random;
  final Offload _offload;

  bool isEncrypted(Uint8List bytes) {
    if (bytes.length < _magic.length) return false;
    for (var i = 0; i < _magic.length; i++) {
      if (bytes[i] != _magic[i]) return false;
    }
    return true;
  }

  Future<Uint8List> encrypt(Uint8List plain, String password) {
    final header = Uint8List(_headerLength)..setAll(0, _magic);
    for (var i = _magic.length; i < _headerLength; i++) {
      header[i] = _random.nextInt(256);
    }
    final rounds = iterations;
    return _offload(() => _seal(header, plain, password, rounds));
  }

  Future<Uint8List> decrypt(Uint8List file, String password) async {
    if (file.length < _headerLength + _tagLength || !isEncrypted(file)) {
      throw const RuleViolation('The backup file is damaged.');
    }
    final rounds = iterations;
    final plain = await _offload(() => _open(file, password, rounds));
    return plain ?? (throw const WrongBackupPassword());
  }
}

Uint8List _seal(Uint8List header, Uint8List plain, String password, int rounds) {
  final sealed = _gcm(header, password, rounds, forEncryption: true).process(plain);
  return Uint8List(_headerLength + sealed.length)
    ..setAll(0, header)
    ..setAll(_headerLength, sealed);
}

Uint8List? _open(Uint8List file, String password, int rounds) {
  final header = Uint8List.sublistView(file, 0, _headerLength);
  try {
    return _gcm(header, password, rounds, forEncryption: false).process(Uint8List.sublistView(file, _headerLength));
  } on InvalidCipherTextException {
    return null;
  }
}

GCMBlockCipher _gcm(Uint8List header, String password, int rounds, {required bool forEncryption}) {
  final salt = Uint8List.sublistView(header, _magic.length, _magic.length + _saltLength);
  final nonce = Uint8List.sublistView(header, _magic.length + _saltLength, _headerLength);
  final key = Uint8List.fromList(pbkdf2Sha256(utf8.encode(password), salt, rounds, 32));
  return GCMBlockCipher(AESEngine())
    ..init(forEncryption, AEADParameters(KeyParameter(key), _tagLength * 8, nonce, header));
}
