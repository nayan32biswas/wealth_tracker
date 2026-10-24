import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wealthtracker/data/db/app_database.dart';
import 'package:wealthtracker/data/io/backup.dart';
import 'package:wealthtracker/data/ledger_store.dart';
import 'package:wealthtracker/data/repositories/drift_repositories.dart';
import 'package:wealthtracker/domain/models/enums.dart';
import 'package:wealthtracker/domain/models/transactions.dart';

void main() {
  late Directory dir;
  late LedgerStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('wt_store');
    store = LedgerStore('${dir.path}/live.sqlite', NativeDatabase.new);
    await store.open();
  });
  tearDown(() async {
    await store.db.close();
    await dir.delete(recursive: true);
  });

  Future<void> addExpense(DriftRepositories repos, String note) async => repos.transactions.save(
    Transaction(
      id: 0,
      type: TransactionType.expense,
      amount: 100,
      assetId: (await repos.assets.all()).first.id,
      categoryId: (await repos.categories.all()).first.id,
      note: note,
      dateTime: DateTime(2026, 9, 1),
    ),
  );

  Future<String> backupWith(String note, {bool lockEnabled = false}) async {
    final db = AppDatabase(NativeDatabase.memory());
    final repos = DriftRepositories(db);
    await addExpense(repos, note);
    await repos.settings.save((await repos.settings.get()).copyWith(lockEnabled: lockEnabled));
    final path = '${dir.path}/backup-$note.sqlite';
    await DriftBackupService(db, repos).exportSqlite(path);
    await db.close();
    return path;
  }

  Future<List<String?>> notes() async =>
      (await store.repos.transactions.find(const TransactionQuery())).map((t) => t.note).toList();

  test('restore replaces the ledger with the backup', () async {
    await addExpense(store.repos, 'on this phone');

    await store.restore(await backupWith('from backup'));

    expect(await notes(), ['from backup']);
  });

  test('a failed restore keeps the current ledger open and intact', () async {
    await addExpense(store.repos, 'on this phone');

    await expectLater(store.restore('${dir.path}/missing.sqlite'), throwsA(anything));

    expect(await notes(), ['on this phone']);
    expect(File('${dir.path}/live.sqlite.restoring').existsSync(), isFalse);
  });

  test('check refuses a file that is not a backup and accepts a real one', () async {
    final junk = File('${dir.path}/junk.sqlite')..writeAsStringSync('not a database');

    expect(store.check(junk.path), 'This is not a Wealth Tracker backup.');
    expect(store.check(await backupWith('from backup')), isNull);
  });

  test('the app lock stays as it is on this phone', () async {
    await store.repos.settings.save(
      (await store.repos.settings.get()).copyWith(lockEnabled: true, lockTimeoutSeconds: 0),
    );

    await store.restore(await backupWith('from backup'));

    final settings = await store.repos.settings.get();
    expect(settings.lockEnabled, isTrue);
    expect(settings.lockTimeoutSeconds, 0);
  });

  test('a backup cannot switch the lock on by itself', () async {
    await store.restore(await backupWith('from backup', lockEnabled: true));

    expect((await store.repos.settings.get()).lockEnabled, isFalse);
  });
}
