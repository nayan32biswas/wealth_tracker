import 'dart:io';

import 'package:drift/drift.dart';

import '../domain/repositories/repositories.dart';
import 'db/app_database.dart';
import 'io/backup.dart';
import 'repositories/drift_repositories.dart';

/// Owns the database file so a restore can swap it safely.
class LedgerStore implements DatabaseRestorer {
  LedgerStore(this.path, this._connect);

  final String path;
  final QueryExecutor Function(File file) _connect;
  late AppDatabase db;
  late DriftRepositories repos;

  /// Where the live file waits while a restore runs.
  String get _previous => '$path.old';

  Future<void> open() async {
    // Only a restore that stopped half-way (the app was closed or crashed)
    // leaves this behind. It is the last file known to be whole, so it goes
    // back; the restore has to be done again, but nothing is lost.
    if (File(_previous).existsSync()) {
      _delete(path);
      _move(_previous, path);
    }
    await _open();
  }

  Future<void> _open() async {
    db = AppDatabase(_connect(File(path)));
    repos = DriftRepositories(db);
    await repos.settings.get();
  }

  @override
  String? check(String backupPath) => checkBackupFile(backupPath, schemaVersion: db.schemaVersion);

  /// The backup is read in full first, so a file this app can't use changes
  /// nothing. Then the live file is moved aside, a new one is created and
  /// filled from the backup through the same writer as CSV import. The old
  /// file is deleted once that has worked, and moved back if anything
  /// failed. App-lock settings belong to this phone and are kept as they are.
  @override
  Future<void> restore(String backupPath) async {
    final data = readBackupFile(backupPath, schemaVersion: db.schemaVersion);
    final device = await repos.settings.get();
    await db.close();
    _move(path, _previous);
    try {
      await _open();
      await repos.importLedger(data, replace: true);
      final restored = await repos.settings.get();
      await repos.settings.save(
        restored.copyWith(
          lockEnabled: device.lockEnabled,
          biometricEnabled: device.biometricEnabled,
          lockTimeoutSeconds: device.lockTimeoutSeconds,
        ),
      );
    } on Object {
      await db.close();
      _delete(path);
      _move(_previous, path);
      await _open();
      rethrow;
    }
    _delete(_previous);
  }

  static const _sideFiles = ['-wal', '-shm', '-journal'];

  static void _move(String from, String to) {
    _delete(to);
    for (final suffix in ['', ..._sideFiles]) {
      final file = File('$from$suffix');
      if (file.existsSync()) file.renameSync('$to$suffix');
    }
  }

  static void _delete(String base) {
    for (final suffix in ['', ..._sideFiles]) {
      final file = File('$base$suffix');
      if (file.existsSync()) file.deleteSync();
    }
  }
}
