import 'dart:io';

import 'package:drift/drift.dart';

import '../domain/repositories/repositories.dart';
import 'db/app_database.dart';
import 'io/backup.dart';
import 'repositories/drift_repositories.dart';

/// Owns the database file so a restore can swap it safely.
class LedgerStore implements DatabaseRestorer {
  LedgerStore(this.path, this._connect, {this._openDatabase = AppDatabase.new});

  final String path;
  final QueryExecutor Function(File file) _connect;
  final AppDatabase Function(QueryExecutor) _openDatabase;
  late AppDatabase db;
  late DriftRepositories repos;

  Future<void> open() async {
    db = _openDatabase(_connect(File(path)));
    repos = DriftRepositories(db);
    await repos.settings.get();
  }

  @override
  String? check(String backupPath) => checkBackupFile(backupPath, schema: db);

  /// The backup is copied next to the live file first. A backup from an
  /// older version is upgraded there, by the same migration an app update
  /// runs, and must then match this version exactly. Only then is the copy
  /// renamed over the live file, so a failure part-way never leaves a broken
  /// ledger. App-lock settings belong to this phone and are kept as they are.
  @override
  Future<void> restore(String backupPath) async {
    final staging = File('$path.restoring');
    try {
      File(backupPath).copySync(staging.path);
      await _upgrade(staging);
    } on Object {
      for (final file in [staging, File('${staging.path}-journal')]) {
        if (file.existsSync()) file.deleteSync();
      }
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

  Future<void> _upgrade(File copy) async {
    final copyDb = _openDatabase(_connect(copy));
    try {
      // The first query opens the file, which runs any pending migration.
      await copyDb.customSelect('SELECT 1').get();
    } on Object {
      throw const RuleViolation('This backup could not be updated for this version of the app.');
    } finally {
      await copyDb.close();
    }
    if (checkBackupFile(copy.path, schema: db) case final problem?) throw RuleViolation(problem);
  }
}
