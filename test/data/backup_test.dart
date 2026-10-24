import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:wealthtracker/data/db/app_database.dart';
import 'package:wealthtracker/data/io/backup.dart';
import 'package:wealthtracker/data/repositories/drift_repositories.dart';
import 'package:wealthtracker/domain/models/enums.dart';
import 'package:wealthtracker/domain/models/transactions.dart';
import 'package:wealthtracker/domain/services/backup_crypto.dart';
import 'package:wealthtracker/domain/services/demo_data.dart';

void main() {
  final today = DateTime(2026, 9, 23);
  late Directory dir;
  late AppDatabase db;
  late DriftRepositories repos;
  late DriftBackupService backup;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('wt_backup');
    db = AppDatabase(NativeDatabase.memory());
    repos = DriftRepositories(db);
    backup = DriftBackupService(db, repos);
  });
  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  (int, int, int) fingerprint(List<Transaction> txns) =>
      (txns.length, txns.fold(0, (s, t) => s + t.amount), txns.fold(0, (s, t) => s + t.fee));

  group('SQLite backup', () {
    test('an exported file opens with identical data', () async {
      await loadDemoData(repos, today);
      final path = '${dir.path}/backup.sqlite';

      await backup.exportSqlite(path);

      expect(checkBackupFile(path, schema: db), isNull);
      final restored = AppDatabase(NativeDatabase(File(path)));
      addTearDown(restored.close);
      final restoredRepos = DriftRepositories(restored);
      expect(
        fingerprint(await restoredRepos.transactions.find(const TransactionQuery())),
        fingerprint(await repos.transactions.find(const TransactionQuery())),
      );
      expect(
        (await restoredRepos.assets.all()).map((a) => a.initialBalance),
        (await repos.assets.all()).map((a) => a.initialBalance),
      );
    });

    test('an encrypted export opens after decrypting', () async {
      await loadDemoData(repos, today);
      final path = '${dir.path}/backup.sqlite';
      await backup.exportSqlite(path);
      final cipher = BackupCipher(iterations: 10, offload: <R>(work) async => work());

      final file = await cipher.encrypt(await File(path).readAsBytes(), 'pw');
      await File(path).writeAsBytes(await cipher.decrypt(file, 'pw'));

      expect(checkBackupFile(path, schema: db), isNull);
    });

    test('a file that is not SQLite is rejected', () async {
      final path = '${dir.path}/notes.sqlite';
      await File(path).writeAsString('just some text, not a database');

      expect(checkBackupFile(path, schema: db), 'This is not a Wealth Tracker backup.');
    });

    test('some other SQLite database is rejected', () async {
      final path = '${dir.path}/other.sqlite';
      sqlite3.open(path)
        ..execute('CREATE TABLE notes (id INTEGER)')
        ..close();

      expect(checkBackupFile(path, schema: db), 'This is not a Wealth Tracker backup.');
    });

    test('a backup whose schema differs from this app is rejected', () async {
      final path = '${dir.path}/backup.sqlite';
      final changes = {
        'other version': 'PRAGMA user_version = 2',
        'renamed column': 'ALTER TABLE "transaction" RENAME COLUMN note TO content',
        'missing table': 'DROP TABLE recurring_rule',
      };

      for (final MapEntry(key: change, value: sql) in changes.entries) {
        if (File(path).existsSync()) File(path).deleteSync();
        await backup.exportSqlite(path);
        sqlite3.open(path)
          ..execute(sql)
          ..close();

        expect(checkBackupFile(path, schema: db), 'This is not a Wealth Tracker backup.', reason: change);
      }
    });
  });

  group('CSV', () {
    test('export writes a header and one readable row per transaction', () async {
      final cash = (await repos.assets.all()).first;
      final food = (await repos.categories.all()).firstWhere((c) => c.name == 'Food');
      await repos.transactions.save(
        Transaction(
          id: 0,
          type: TransactionType.expense,
          amount: 65050,
          fee: 100,
          assetId: cash.id,
          categoryId: food.id,
          note: 'Lunch, with "friends"',
          dateTime: DateTime(2026, 9, 5, 13, 7),
        ),
      );

      final lines = (await backup.exportCsv()).trim().split('\r\n');

      expect(lines.first, 'date,time,type,amount,fee,account,to_account,category,note');
      expect(lines[1], '2026-09-05,13:07,expense,650.50,1.00,Cash,,Food,"Lunch, with ""friends"""');
    });

    test('export then import into a fresh ledger gives the same entries', () async {
      await loadDemoData(repos, today);
      final text = await backup.exportCsv();

      final otherDb = AppDatabase(NativeDatabase.memory());
      addTearDown(otherDb.close);
      final other = DriftRepositories(otherDb);
      final otherBackup = DriftBackupService(otherDb, other);
      final preview = await otherBackup.previewCsv(text);
      expect(preview.errors, isEmpty);
      await otherBackup.importCsv(preview);

      expect(
        fingerprint(await other.transactions.find(const TransactionQuery())),
        fingerprint(await repos.transactions.find(const TransactionQuery())),
      );
    });

    test('preview lists new accounts and categories without saving anything', () async {
      const text =
          'date,time,type,amount,fee,account,to_account,category,note\r\n'
          '2026-09-01,09:00,expense,120,0,Petty Cash,,Pets,Cat food\r\n'
          '2026-09-02,10:00,transfer,50,0,Bank Account,Petty Cash,,\r\n';

      final preview = await backup.previewCsv(text);

      expect(preview.rows, hasLength(2));
      expect(preview.newAccounts, {'Petty Cash'});
      expect(preview.newCategories, {'Expense: Pets'});
      expect(await repos.transactions.hasAny(), isFalse);

      await backup.importCsv(preview);
      expect((await repos.assets.all()).map((a) => a.name), contains('Petty Cash'));
      expect(await repos.transactions.find(const TransactionQuery()), hasLength(2));
    });

    test('bad rows are reported by line and block the import', () async {
      const text =
          'date,time,type,amount,fee,account,to_account,category,note\r\n'
          '2026-13-01,09:00,expense,120,0,Cash,,Food,\r\n'
          '2026-09-01,09:00,gift,120,0,Cash,,Food,\r\n'
          '2026-09-01,09:00,expense,abc,0,Cash,,Food,\r\n'
          '2026-09-01,09:00,transfer,10,0,Cash,,,\r\n'
          '2026-09-01,09:00,expense,10,0,Cash,,,\r\n';

      final preview = await backup.previewCsv(text);

      expect(preview.errors, [
        'Line 2: date must look like 2026-09-23',
        'Line 3: type must be income, expense or transfer',
        'Line 4: amount is not a valid number',
        'Line 5: a transfer needs to_account',
        'Line 6: income and expense need a category',
      ]);
      expect(preview.canImport, isFalse);
    });

    test('rows the form would refuse are refused in CSV too', () async {
      const text =
          'date,time,type,amount,fee,account,to_account,category,note\r\n'
          '2026-09-01,09:00,income,3,5,Cash,,Salary,\r\n'
          '2026-09-01,09:00,transfer,10,0,Cash,Cash,,\r\n';

      expect((await backup.previewCsv(text)).errors, [
        "Line 2: the fee can't be more than the amount",
        'Line 3: a transfer needs two different accounts',
      ]);
    });

    test('a byte-order mark from Excel is ignored', () async {
      final preview = await backup.previewCsv(
        '${String.fromCharCode(0xFEFF)}date,time,type,amount,fee,account,to_account,category,note\r\n'
        '2026-09-01,09:00,expense,5,0,Cash,,Food,\r\n',
      );

      expect(preview.errors, isEmpty);
      expect(preview.rows, hasLength(1));
    });

    test('a file with the wrong columns is rejected', () async {
      final preview = await backup.previewCsv('when,how much\r\n2026-09-01,5\r\n');

      expect(preview.errors, ['The first line must be: date,time,type,amount,fee,account,to_account,category,note']);
    });
  });
}
