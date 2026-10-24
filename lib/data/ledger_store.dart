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

  Future<void> open() async {
    db = AppDatabase(_connect(File(path)));
    repos = DriftRepositories(db);
    await repos.settings.get();
  }

  @override
  String? check(String backupPath) => checkBackupFile(backupPath, schema: db);

  /// The backup is copied next to the live file first, then renamed over it,
  /// so a failure part-way never leaves a broken ledger. App-lock settings
  /// belong to this phone and are kept as they are.
  @override
  Future<void> restore(String backupPath) async {
    final staging = File('$path.restoring');
    try {
      File(backupPath).copySync(staging.path);
    } on Object {
      if (staging.existsSync()) staging.deleteSync();
      rethrow;
    }

    final device = await repos.settings.get();
    await db.close();
    try {
      for (final suffix in ['-wal', '-shm', '-journal']) {
        final side = File('$path$suffix');
        if (side.existsSync()) side.deleteSync();
      }
      staging.renameSync(path);
    } finally {
      await open();
    }
    final restored = await repos.settings.get();
    await repos.settings.save(
      restored.copyWith(
        lockEnabled: device.lockEnabled,
        biometricEnabled: device.biometricEnabled,
        lockTimeoutSeconds: device.lockTimeoutSeconds,
      ),
    );
  }
}
