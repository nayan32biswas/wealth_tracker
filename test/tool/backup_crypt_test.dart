import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wealthtracker/domain/repositories/repositories.dart';
import 'package:wealthtracker/domain/services/backup_crypto.dart';

import '../../tool/backup_crypt.dart';

Future<R> inline<R>(FutureOr<R> Function() work) async => work();

BackupCipher fastCipher() => BackupCipher(iterations: 10, offload: inline);

final sqlite = Uint8List.fromList([...ascii.encode('SQLite format 3'), 0, ...List.filled(200, 7)]);

void main() {
  test('encrypt makes a file the app opens with the same password', () async {
    final file = await convertBackup('encrypt', sqlite, 'correct horse', fastCipher());

    expect(await fastCipher().decrypt(file, 'correct horse'), sqlite);
  });

  test('decrypt opens a file the app made', () async {
    final file = await fastCipher().encrypt(sqlite, 'correct horse');

    expect(await convertBackup('decrypt', file, 'correct horse', fastCipher()), sqlite);
  });

  test('decrypt with the wrong password fails with the app message', () async {
    final file = await fastCipher().encrypt(sqlite, 'correct horse');

    await expectLater(convertBackup('decrypt', file, 'wrong horse', fastCipher()), throwsA(isA<WrongBackupPassword>()));
  });

  test('decrypt refuses a plain SQLite file', () async {
    await expectLater(
      convertBackup('decrypt', sqlite, 'correct horse', fastCipher()),
      throwsA(isA<RuleViolation>().having((e) => e.message, 'message', 'This is not an encrypted backup.')),
    );
  });

  test('encrypt refuses a file that is already encrypted', () async {
    final file = await fastCipher().encrypt(sqlite, 'correct horse');

    await expectLater(
      convertBackup('encrypt', file, 'correct horse', fastCipher()),
      throwsA(isA<RuleViolation>().having((e) => e.message, 'message', 'This backup is already encrypted.')),
    );
  });

  test('encrypt refuses a file that is not SQLite', () async {
    await expectLater(
      convertBackup('encrypt', Uint8List.fromList(utf8.encode('date,amount\n')), 'correct horse', fastCipher()),
      throwsA(isA<RuleViolation>().having((e) => e.message, 'message', 'This is not a SQLite backup.')),
    );
  });
}
