// Engine for tool/backup_crypt.sh. Run that script instead of this file: it
// handles the password prompt and won't overwrite files by accident.
//
// Usage: dart tool/backup_crypt.dart <encrypt|decrypt> <input> <output>
// The password is read from stdin.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:wealthtracker/domain/repositories/repositories.dart';
import 'package:wealthtracker/domain/services/backup_crypto.dart';

final _sqliteMagic = ascii.encode('SQLite format 3\x00');

Future<Uint8List> convertBackup(String mode, Uint8List input, String password, BackupCipher cipher) async {
  switch (mode) {
    case 'decrypt':
      if (!cipher.isEncrypted(input)) throw const RuleViolation('This is not an encrypted backup.');
      return cipher.decrypt(input, password);
    case 'encrypt':
      if (cipher.isEncrypted(input)) throw const RuleViolation('This backup is already encrypted.');
      if (!_startsWith(input, _sqliteMagic)) throw const RuleViolation('This is not a SQLite backup.');
      return cipher.encrypt(input, password);
    default:
      throw ArgumentError.value(mode, 'mode');
  }
}

bool _startsWith(Uint8List bytes, List<int> prefix) {
  if (bytes.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (bytes[i] != prefix[i]) return false;
  }
  return true;
}

Future<void> main(List<String> args) async {
  if (args.length != 3 || !const {'encrypt', 'decrypt'}.contains(args[0])) {
    stderr.writeln('Usage: dart tool/backup_crypt.dart <encrypt|decrypt> <input> <output>');
    exit(64);
  }
  final [mode, inputPath, outputPath] = args;
  final password = (await utf8.decoder.bind(stdin).join()).replaceFirst(RegExp(r'\r?\n$'), '');
  try {
    final input = await File(inputPath).readAsBytes();
    final output = await convertBackup(mode, input, password, BackupCipher());
    await File(outputPath).writeAsBytes(output, flush: true);
  } on RuleViolation catch (e) {
    stderr.writeln(e.message);
    exit(1);
  } on FileSystemException catch (e) {
    stderr.writeln('Could not read or write the file: ${e.path ?? ''} ${e.osError?.message ?? e.message}');
    exit(1);
  }
}
