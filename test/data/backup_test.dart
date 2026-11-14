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

  (int, int) fingerprint(List<Transaction> txns) => (txns.length, txns.fold(0, (s, t) => s + t.amount));

  group('SQLite backup', () {
    test('an exported file opens with identical data', () async {
      await loadDemoData(repos, today);
      final path = '${dir.path}/backup.sqlite';

      await backup.exportSqlite(path);

      expect(checkBackupFile(path, schemaVersion: db.schemaVersion), isNull);
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

      expect(checkBackupFile(path, schemaVersion: db.schemaVersion), isNull);
    });

    test('a file that is not SQLite is rejected', () async {
      final path = '${dir.path}/notes.sqlite';
      await File(path).writeAsString('just some text, not a database');

      expect(checkBackupFile(path, schemaVersion: db.schemaVersion), 'This is not a Wealth Tracker backup.');
    });

    test('some other SQLite database is rejected', () async {
      final path = '${dir.path}/other.sqlite';
      sqlite3.open(path)
        ..execute('CREATE TABLE notes (id INTEGER)')
        ..close();

      expect(checkBackupFile(path, schemaVersion: db.schemaVersion), 'This is not a Wealth Tracker backup.');
    });

    test('a backup without what every version has is rejected', () async {
      final path = '${dir.path}/backup.sqlite';
      final changes = {
        'no version': 'PRAGMA user_version = 0',
        'missing required column': 'ALTER TABLE "transaction" RENAME COLUMN asset_id TO wallet',
        'missing table': 'DROP TABLE recurring_rule',
        // The tables have no CHECK on these columns; the reader's enums
        // are what keep an unknown value out.
        'unknown entry type': "UPDATE \"transaction\" SET type = 'gift'",
        'unknown category type': "UPDATE category SET type = 'gift'",
        'unknown group type': "UPDATE asset_group SET type = 'gift'",
      };
      await loadDemoData(repos, today, months: 1);

      for (final MapEntry(key: change, value: sql) in changes.entries) {
        if (File(path).existsSync()) File(path).deleteSync();
        await backup.exportSqlite(path);
        sqlite3.open(path)
          ..execute(sql)
          ..close();

        expect(
          checkBackupFile(path, schemaVersion: db.schemaVersion),
          'This is not a Wealth Tracker backup.',
          reason: change,
        );
      }
    });

    test('columns another version added or removed are read by name', () async {
      await loadDemoData(repos, today, months: 1);
      final path = '${dir.path}/backup.sqlite';
      await backup.exportSqlite(path);
      sqlite3.open(path)
        ..execute('ALTER TABLE "transaction" ADD COLUMN tag TEXT')
        ..execute('ALTER TABLE "transaction" DROP COLUMN note')
        ..execute('ALTER TABLE asset DROP COLUMN is_archived')
        ..execute("INSERT INTO setting VALUES ('unknown_setting', 'x')")
        ..close();

      final data = readBackupFile(path, schemaVersion: db.schemaVersion);

      final txns = await repos.transactions.find(const TransactionQuery());
      expect(data.transactions.map((t) => t.amount), unorderedEquals(txns.map((t) => t.amount)));
      expect(data.transactions.every((t) => t.note == null), isTrue);
      expect(data.accounts.every((a) => !a.isArchived), isTrue);
    });

    test('a backup from a newer version asks for an app update', () async {
      final path = '${dir.path}/backup.sqlite';
      await backup.exportSqlite(path);
      sqlite3.open(path)
        ..execute('PRAGMA user_version = ${db.schemaVersion + 1}')
        ..close();

      expect(
        checkBackupFile(path, schemaVersion: db.schemaVersion),
        'This backup is from a newer version of Wealth Tracker. Update the app, then restore it.',
      );
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
          assetId: cash.id,
          categoryId: food.id,
          note: 'Lunch, with "friends"',
          dateTime: DateTime(2026, 9, 5, 13, 7),
        ),
      );

      final lines = (await backup.exportCsv()).trim().split('\r\n');

      expect(lines.first, 'date,time,type,amount,account,to_account,category,note,linked_to');
      expect(lines[1], '2026-09-05,13:07,expense,650.50,Cash,,Food,"Lunch, with ""friends""",');
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

    test('a fee is written with the line of its entry and comes back linked', () async {
      final bank = (await repos.assets.all()).firstWhere((a) => a.name == 'Bank Account');
      final salary = (await repos.categories.all()).firstWhere((c) => c.name == 'Salary');
      final tds = await repos.categories.add('TDS', CategoryType.expense);
      await repos.transactions.save(
        Transaction(
          id: 0,
          type: TransactionType.income,
          amount: 10000000,
          assetId: bank.id,
          categoryId: salary.id,
          note: 'October',
          dateTime: DateTime(2026, 10, 31, 9),
        ),
        fee: Fee(amount: 500000, categoryId: tds),
      );

      final text = await backup.exportCsv();
      expect(text.trim().split('\r\n').skip(1), [
        '2026-10-31,09:00,income,100000.00,Bank Account,,Salary,October,',
        '2026-10-31,09:00,expense,5000.00,Bank Account,,TDS,October,2',
      ]);

      final otherDb = AppDatabase(NativeDatabase.memory());
      addTearDown(otherDb.close);
      final other = DriftRepositories(otherDb);
      final otherBackup = DriftBackupService(otherDb, other);
      await otherBackup.importCsv(await otherBackup.previewCsv(text));
      final imported = await other.transactions.find(const TransactionQuery(types: {TransactionType.income}));
      expect((await other.transactions.feeOf(imported.single.id))?.amount, 500000);
    });

    test('a bad linked_to is reported by line', () async {
      const text =
          'date,time,type,amount,account,to_account,category,note,linked_to\r\n'
          '2026-09-01,09:00,income,100,Cash,,Salary,,\r\n'
          '2026-09-01,09:00,expense,5,Cash,,Food,,2\r\n'
          '2026-09-01,09:00,expense,5,Cash,,Food,,2\r\n'
          '2026-09-01,09:00,expense,5,Cash,,Food,,3\r\n'
          '2026-09-01,09:00,income,5,Cash,,Salary,,2\r\n'
          '2026-09-01,09:00,expense,5,Cash,,Food,,9\r\n'
          '2026-09-01,09:00,expense,5,Cash,,Food,,x\r\n'
          '2026-09-01,09:00,expense,5,Bank,,Food,,2\r\n'
          '2026-09-02,09:00,expense,5,Cash,,Food,,2\r\n'
          '2026-09-01,09:00,expense,5,Cash,,Food,typo,2\r\n';

      expect((await backup.previewCsv(text)).errors, [
        'Line 4: line 2 already has a fee',
        'Line 5: linked_to points to a line that is itself a fee',
        'Line 6: only an expense can be linked as a fee',
        'Line 7: linked_to must be the line number of an earlier entry',
        'Line 8: linked_to must be a line number',
        'Line 9: a fee must have the same account, date, time and note as line 2',
        'Line 10: a fee must have the same account, date, time and note as line 2',
        'Line 11: a fee must have the same account, date, time and note as line 2',
      ]);
    });

    test('preview lists new accounts and categories without saving anything', () async {
      const text =
          'date,time,type,amount,account,to_account,category,note\r\n'
          '2026-09-01,09:00,expense,120,Petty Cash,,Pets,Cat food\r\n'
          '2026-09-02,10:00,transfer,50,Bank Account,Petty Cash,,\r\n';

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
          'date,time,type,amount,account,to_account,category,note\r\n'
          '2026-13-01,09:00,expense,120,Cash,,Food,\r\n'
          '2026-09-01,09:00,gift,120,Cash,,Food,\r\n'
          '2026-09-01,09:00,expense,abc,Cash,,Food,\r\n'
          '2026-09-01,09:00,transfer,10,Cash,,,\r\n'
          '2026-09-01,09:00,expense,10,Cash,,,\r\n';

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
          'date,time,type,amount,account,to_account,category,note\r\n'
          '2026-09-01,09:00,transfer,10,Cash,Cash,,\r\n';

      expect((await backup.previewCsv(text)).errors, ['Line 2: a transfer needs two different accounts']);
    });

    test('a negative amount imports as a refund, keeping its sign', () async {
      const text =
          'date,time,type,amount,account,to_account,category,note\r\n'
          '2026-09-01,09:00,expense,-25.50,Cash,,Food,Returned\r\n'
          '2026-09-02,09:00,expense,-abc,Cash,,Food,\r\n';

      expect((await backup.previewCsv(text)).errors, ['Line 3: amount is not a valid number']);

      await backup.importCsv(await backup.previewCsv(text.split('\r\n').take(2).join('\r\n')));
      expect((await repos.transactions.find(const TransactionQuery())).single.amount, -2550);
    });

    test('a negative transfer imports, keeping its sign', () async {
      const text =
          'date,time,type,amount,account,to_account,category,note\r\n'
          '2026-09-01,09:00,transfer,-10,Bank Account,Cash,,Back to the bank\r\n';

      expect((await backup.previewCsv(text)).errors, isEmpty);
      await backup.importCsv(await backup.previewCsv(text));
      expect((await repos.transactions.find(const TransactionQuery())).single.amount, -1000);
    });

    test('a 0 amount imports as 0', () async {
      const text =
          'date,time,type,amount,account,to_account,category,note\r\n'
          '2026-09-01,09:00,expense,0,Cash,,Food,Free sample\r\n';

      await backup.importCsv(await backup.previewCsv(text));
      expect((await repos.transactions.find(const TransactionQuery())).single.amount, 0);
    });

    test('a byte-order mark from Excel is ignored', () async {
      final preview = await backup.previewCsv(
        '${String.fromCharCode(0xFEFF)}date,time,type,amount,account,to_account,category,note\r\n'
        '2026-09-01,09:00,expense,5,Cash,,Food,\r\n',
      );

      expect(preview.errors, isEmpty);
      expect(preview.rows, hasLength(1));
    });

    test('columns are found by name: any order, extra ones ignored, optional ones left out', () async {
      const text =
          'Amount,type,tag,date,account,time,category\r\n'
          '120,expense,lunch,2026-09-01,Cash,09:00,Food\r\n';

      final preview = await backup.previewCsv(text);
      expect(preview.errors, isEmpty);
      await backup.importCsv(preview);

      final t = (await repos.transactions.find(const TransactionQuery())).single;
      expect((t.amount, t.note, t.dateTime), (12000, null, DateTime(2026, 9, 1, 9)));
    });

    test('line endings from any tool read the same, blank lines at the end are skipped', () async {
      const lines = [
        'date,time,type,amount,account,to_account,category,note',
        '2026-09-01,09:00,expense,5,Cash,,Food,a',
        '2026-09-02,10:00,expense,6,Cash,,Food,b',
      ];
      for (final MapEntry(key: tool, value: eol) in {'Windows': '\r\n', 'Linux, Mac': '\n', 'old Mac': '\r'}.entries) {
        final preview = await backup.previewCsv('${lines.join(eol)}$eol$eol$eol');

        expect(preview.errors, isEmpty, reason: tool);
        expect(preview.rows.map((r) => r.note), ['a', 'b'], reason: tool);
      }
    });

    test('a semicolon-separated file and amounts with thousands separators import', () async {
      final semicolons = await backup.previewCsv(
        'date;time;type;amount;account;to_account;category;note\r\n'
        '2026-09-01;09:00;expense;5;Cash;;Food;a\r\n',
      );
      final grouped = await backup.previewCsv(
        'date,time,type,amount,account,to_account,category,note\r\n'
        '2026-09-01,09:00,expense,"1,234.50",Cash,,Food,a\r\n',
      );

      expect(semicolons.errors, isEmpty);
      expect(semicolons.rows.single.amount, 500);
      expect(grouped.errors, isEmpty);
      expect(grouped.rows.single.amount, 123450);
    });

    test('Bengali and emoji names and tricky notes come back the same after export and import', () async {
      final wallet = await repos.assets.add('নগদ 💵', (await repos.groups.all()).first.id);
      final food = await repos.categories.add('খাবার 🍔', CategoryType.expense);
      const notes = ['007', 'line one\nline two', 'a, "quoted" note', '=SUM(A1)', '১২৩ টাকা'];
      for (final note in notes) {
        await repos.transactions.save(
          Transaction(
            id: 0,
            type: TransactionType.expense,
            amount: 100,
            assetId: wallet,
            categoryId: food,
            note: note,
            dateTime: DateTime(2026, 9, 1),
          ),
        );
      }
      final text = await backup.exportCsv();

      final otherDb = AppDatabase(NativeDatabase.memory());
      addTearDown(otherDb.close);
      final other = DriftRepositories(otherDb);
      final otherBackup = DriftBackupService(otherDb, other);
      await otherBackup.importCsv(await otherBackup.previewCsv(text));

      final imported = await other.transactions.find(const TransactionQuery());
      expect(imported.map((t) => t.note), unorderedEquals(notes));
      expect((await other.assets.all()).map((a) => a.name), contains('নগদ 💵'));
      expect((await other.categories.all()).map((c) => c.name), contains('খাবার 🍔'));
    });

    test('a file with the wrong columns is rejected', () async {
      final preview = await backup.previewCsv('when,how much\r\n2026-09-01,5\r\n');

      expect(preview.errors, [
        'The first line must name these columns: date,time,type,amount,account,to_account,category,note,linked_to',
      ]);
    });
  });
}
