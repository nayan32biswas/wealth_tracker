import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:wealthtracker/data/db/app_database.dart';
import 'package:wealthtracker/data/io/backup.dart';
import 'package:wealthtracker/data/ledger_store.dart';
import 'package:wealthtracker/data/repositories/drift_repositories.dart';
import 'package:wealthtracker/domain/models/enums.dart';
import 'package:wealthtracker/domain/models/transactions.dart';
import 'package:wealthtracker/domain/repositories/repositories.dart';

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

  test('a file that is not a backup changes nothing', () async {
    await addExpense(store.repos, 'on this phone');

    await expectLater(store.restore('${dir.path}/missing.sqlite'), throwsA(isA<RuleViolation>()));

    expect(await notes(), ['on this phone']);
    expect(File('${store.path}.old').existsSync(), isFalse);
  });

  test('check names a bad entry, so nothing is replaced', () async {
    await addExpense(store.repos, 'on this phone');
    final backup = await backupWith('from backup');
    sqlite3.open(backup)
      ..execute('UPDATE "transaction" SET asset_id = 999')
      ..close();
    const problem = "This backup can't be restored. Entry 1: its account is missing.";

    expect(store.check(backup), problem);
    await expectLater(
      store.restore(backup),
      throwsA(isA<RuleViolation>().having((e) => e.message, 'message', problem)),
    );

    expect(await notes(), ['on this phone']);
    expect(File('${store.path}.old').existsSync(), isFalse);
  });

  test('a failure while importing puts the old file back', () async {
    await store.db.close();
    // The first open is the live file; the second, the new file a restore
    // fills, fails.
    var opens = 0;
    store = LedgerStore(
      store.path,
      (file) => opens++ == 1 ? throw const FileSystemException('disk full') : NativeDatabase(file),
    );
    await store.open();
    await addExpense(store.repos, 'on this phone');

    await expectLater(store.restore(await backupWith('from backup')), throwsA(isA<FileSystemException>()));

    expect(await notes(), ['on this phone']);
    expect(File('${store.path}.old').existsSync(), isFalse);
  });

  test('a restore that stopped half-way is undone on the next start', () async {
    await addExpense(store.repos, 'on this phone');
    await store.db.close();
    File(store.path).renameSync('${store.path}.old');
    File(store.path).writeAsStringSync('half-written');

    await store.open();

    expect(await notes(), ['on this phone']);
    expect(File('${store.path}.old').existsSync(), isFalse);
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

  // Real backups from older versions. When the schema changes, add a backup
  // made by the version before it here, so old backups keep restoring.
  group('a backup from an older version restores', () {
    Future<Map<String, int>> balances() async {
      final accounts = [...await store.repos.assets.all(), ...await store.repos.assets.watchArchived().first];
      final deltas = await store.repos.transactions.watchBalanceDeltas().first;
      return {for (final a in accounts) a.name: a.initialBalance + (deltas[a.id] ?? 0)};
    }

    test('v1 from 2026-11-01', () async {
      const backup = 'test/fixtures/backups/v1-2026-11-01.sqlite';

      expect(store.check(backup), isNull);
      await store.restore(backup);

      final repos = store.repos;
      final txns = await repos.transactions.find(const TransactionQuery());
      expect((txns.length, txns.fold(0, (s, t) => s + t.amount)), (154, 40455700));
      // Columns this version doesn't have are skipped, so balances follow the amounts alone.
      expect(await balances(), {
        'Cash': -182200,
        'Bank Account': 25800000,
        'Mobile Wallet': -2015200,
        'Credit Card': -953800,
        'Old Wallet': 7800,
      });
      expect((await repos.assets.watchArchived().first).map((a) => a.name), ['Old Wallet']);
      expect((await repos.categories.watchDeleted().first).map((c) => c.name), ['Pets']);
      expect(txns.where((t) => t.note == 'Vet, with fee').single.categoryId, isNotNull);
      expect((await repos.recurring.active()).map((r) => r.note), ['House rent']);
      expect(txns.where((t) => t.note == 'Old weekly gift').single.recurringRuleId, isNotNull);
      expect(await repos.groups.all(), hasLength(5));
      expect((await repos.settings.get()).currencyCode, 'USD');
    });

    test('v1 from 2026-11-02, before fees were linked', () async {
      const backup = 'test/fixtures/backups/v1-2026-11-02.sqlite';

      expect(store.check(backup), isNull);
      await store.restore(backup);

      final txns = await store.repos.transactions.find(const TransactionQuery());
      expect((txns.length, txns.fold(0, (s, t) => s + t.amount)), (5, 12547000));
      // The fees typed by hand back then stay plain expenses.
      expect(txns.where((t) => t.isFee), isEmpty);
      expect(await balances(), containsPair('Bank Account', 7498000));
      expect(await balances(), containsPair('Cash', 1955000));
    });
  });

  test('a fee stays linked to its entry through a backup', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final repos = DriftRepositories(db);
    final bank = (await repos.assets.all()).firstWhere((a) => a.name == 'Bank Account').id;
    final salary = (await repos.categories.all()).firstWhere((c) => c.name == 'Salary').id;
    final tds = await repos.categories.add('TDS', CategoryType.expense);
    // An entry without a fee first, so the ids in the file and the restored
    // ledger can differ.
    await addExpense(repos, 'lunch');
    await repos.transactions.save(
      Transaction(
        id: 0,
        type: TransactionType.income,
        amount: 100000,
        assetId: bank,
        categoryId: salary,
        note: 'salary',
        dateTime: DateTime(2026, 9, 30),
      ),
      fee: Fee(amount: 5000, categoryId: tds),
    );
    final path = '${dir.path}/with-fee.sqlite';
    await DriftBackupService(db, repos).exportSqlite(path);
    await db.close();

    await store.restore(path);

    final txns = await store.repos.transactions.find(const TransactionQuery());
    final main = txns.singleWhere((t) => t.note == 'salary' && !t.isFee);
    expect((await store.repos.transactions.feeOf(main.id))?.amount, 5000);
  });
}
