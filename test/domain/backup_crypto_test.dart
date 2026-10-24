import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wealthtracker/domain/repositories/repositories.dart';
import 'package:wealthtracker/domain/services/backup_crypto.dart';

Future<R> inline<R>(FutureOr<R> Function() work) async => work();

BackupCipher fastCipher() => BackupCipher(iterations: 10, offload: inline);

final sqlite = Uint8List.fromList([...ascii.encode('SQLite format 3'), 0, ...List.filled(200, 7)]);

Uint8List flipped(Uint8List bytes, int index) => Uint8List.fromList(bytes)..[index] ^= 0x01;

void main() {
  test('encrypts and decrypts back to the same bytes', () async {
    final cipher = fastCipher();
    final file = await cipher.encrypt(sqlite, 'correct horse');

    expect(cipher.isEncrypted(file), isTrue);
    expect(ascii.decode(file.sublist(0, 8)), 'WTBACKUP');
    expect(file.length, sqlite.length + 52);
    expect(file.sublist(36, 51), isNot(sqlite.sublist(0, 15)));
    expect(await cipher.decrypt(file, 'correct horse'), sqlite);
  });

  test('a brand-new cipher opens the file, as on another phone', () async {
    final file = await fastCipher().encrypt(sqlite, 'correct horse');

    expect(await fastCipher().decrypt(file, 'correct horse'), sqlite);
  });

  test('plain SQLite and junk are not encrypted backups', () {
    final cipher = fastCipher();

    expect(cipher.isEncrypted(sqlite), isFalse);
    expect(cipher.isEncrypted(Uint8List(0)), isFalse);
    expect(cipher.isEncrypted(Uint8List.fromList([1, 2, 3])), isFalse);
  });

  test('the same data encrypts differently each time', () async {
    final cipher = fastCipher();

    expect(await cipher.encrypt(sqlite, 'pw'), isNot(await cipher.encrypt(sqlite, 'pw')));
  });

  test('a wrong password is refused', () async {
    final cipher = fastCipher();
    final file = await cipher.encrypt(sqlite, 'right');

    await expectLater(cipher.decrypt(file, 'wrong'), throwsA(isA<WrongBackupPassword>()));
  });

  test('any changed byte is caught', () async {
    final cipher = fastCipher();
    final file = await cipher.encrypt(sqlite, 'pw');
    final places = {'salt': 8, 'nonce': 24, 'ciphertext': 36, 'tag': file.length - 1};

    for (final MapEntry(key: part, value: index) in places.entries) {
      await expectLater(cipher.decrypt(flipped(file, index), 'pw'), throwsA(isA<WrongBackupPassword>()), reason: part);
    }
  });

  test('a cut-short file is damaged', () async {
    final cipher = fastCipher();
    final file = await cipher.encrypt(Uint8List(0), 'pw');

    expect(file.length, 52);
    await expectLater(
      cipher.decrypt(file.sublist(0, 51), 'pw'),
      throwsA(isA<RuleViolation>().having((e) => e.message, 'message', 'The backup file is damaged.')),
    );
  });

  test('works in a background isolate', () async {
    final cipher = BackupCipher(iterations: 10);

    expect(await cipher.decrypt(await cipher.encrypt(sqlite, 'pw'), 'pw'), sqlite);
  });
}
