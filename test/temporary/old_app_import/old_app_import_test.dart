// TEMPORARY: delete with lib/temporary/old_app_import/.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:wealthtracker/data/db/app_database.dart';
import 'package:wealthtracker/data/io/backup.dart';
import 'package:wealthtracker/data/repositories/drift_repositories.dart';
import 'package:wealthtracker/domain/models/app_settings.dart';
import 'package:wealthtracker/temporary/old_app_import/old_app_converter.dart';

import '../../presentation/harness.dart';

// 2026-01-01 20:00 UTC is already 2 January on the old phone (UTC+06:00).
final _evening = DateTime.utc(2026, 1, 1, 20).millisecondsSinceEpoch;

/// A small database laid out like the old app's, with one row for each rule.
String oldAppFile(String dir) {
  final path = p.join(dir, 'old.sqlite');
  final db = sqlite3.open(path);
  db.execute('''
    CREATE TABLE ASSETGROUP (DEVICE_ID INTEGER PRIMARY KEY, IS_DEL INTEGER, USETIME INTEGER,
      ACC_GROUP_NAME VARCHAR, ORDERSEQ INTEGER, uid TEXT);
    CREATE TABLE ASSETS (ID INTEGER PRIMARY KEY, NIC_NAME VARCHAR, ORDERSEQ INTEGER, A_UTIME INTEGER,
      uid TEXT, groupUid TEXT);
    CREATE TABLE ZCATEGORY (ID INTEGER PRIMARY KEY, C_IS_DEL INTEGER, C_UTIME INTEGER, NAME VARCHAR,
      ORDERSEQ INTEGER, TYPE INTEGER, STATUS INTEGER, uid TEXT);
    CREATE TABLE INOUTCOME (AID INTEGER PRIMARY KEY, ZCONTENT VARCHAR, ZDATE VARCHAR, WDATE VARCHAR,
      DO_TYPE VARCHAR, UTIME INTEGER, AMOUNT_ACCOUNT REAL, uid TEXT, assetUid TEXT, txUidTrans TEXT,
      ctgUid TEXT, toAssetUid TEXT);
    INSERT INTO ASSETGROUP VALUES (1, 0, 1000, 'Cash ', 0, 'g1');
    INSERT INTO ASSETS VALUES (1, 'Wallet', 0, 1000, 'a1', 'g1'), (2, ' Bank ', 1, 1000, 'a2', 'g1');
    INSERT INTO ZCATEGORY VALUES (1, 0, 1000, 'Food', 0, 1, 0, 'c1'), (2, 0, 1000, 'Salary', 1, 0, 0, 'c2'),
      (3, 0, 1000, 'Hidden', 2, 1, 2, 'c3');
  ''');
  final add = db.prepare(
    'INSERT INTO INOUTCOME (AID, ZCONTENT, ZDATE, DO_TYPE, UTIME, AMOUNT_ACCOUNT, '
    'assetUid, ctgUid, txUidTrans) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
  );
  for (final row in [
    [1, ' Pay ', '$_evening', '0', 5, 1000.5, 'a1', 'c2', ''],
    [2, 'Refund', '$_evening', '1', 5, -50.0, 'a1', 'c1', ''],
    [3, '', '$_evening', '1', 5, 0.0, 'a1', 'c1', ''],
    [4, '', '$_evening', '9', 5, 90.0, 'a1', 'c1', ''],
    [5, '', '$_evening', '3', 5, 300.0, 'a1', null, 'x'],
    [6, 'To bank', '$_evening', '4', 5, 300.0, 'a2', null, 'x'],
    [7, '', '$_evening', '3', 5, 10.0, 'a1', null, 'lonely'],
    [8, 'Tea', '$_evening', '1', 5, 1.005, 'a1', 'c1', ''],
  ]) {
    add.execute(row);
  }
  add.close();
  db.close();
  return path;
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('old_app'));
  tearDown(() => dir.deleteSync(recursive: true));

  group('reading the old data', () {
    late OldAppData data;
    setUp(() => data = readOldApp(oldAppFile(dir.path), nowMs: 99));
    Map<String, Object?> txn(int id) => data.transactions.singleWhere((t) => t['id'] == id);

    test('a transfer pair becomes one transfer from the out row to the in row', () {
      expect(txn(5), containsPair('type', 'transfer'));
      expect((txn(5)['asset_id'], txn(5)['to_asset_id'], txn(5)['amount']), (1, 2, 30000));
      expect(txn(5)['note'], 'To bank');
      expect(data.transactions.where((t) => t['id'] == 6), isEmpty);
    });

    test('a negative expense stays a negative expense in its own category', () {
      expect((txn(2)['type'], txn(2)['amount'], txn(2)['category_id']), ('expense', -5000, 1));
      expect(data.changed, isEmpty);
    });

    test('amounts round half up to paisa as written', () {
      expect(txn(1)['amount'], 100050);
      expect(txn(8)['amount'], 101);
      expect(toPaisa(650.1), 65010);
    });

    test('dates are the old phone\'s, and names and notes are trimmed', () {
      expect(txn(1)['date'], '2026-01-02');
      expect(txn(1)['note'], 'Pay');
      expect(data.groups.single['name'], 'Cash');
      expect(data.assets.last['name'], 'Bank');
    });

    test('rows that cannot be kept are listed, and hidden categories left out', () {
      expect(data.skipped, {
        'zero amount': [3],
        'no type': [4],
        'transfer without one matching out and in row': [7],
      });
      expect(data.categories.values.map((c) => c['name']), isNot(contains('Hidden')));
    });

    test('a file from another app is refused', () {
      final other = p.join(dir.path, 'other.sqlite');
      sqlite3.open(other)
        ..execute('CREATE TABLE notes (id INTEGER)')
        ..close();
      expect(() => readOldApp(other, nowMs: 0), throwsFormatException);
    });
  });

  test('the written file is a backup Restore accepts, with only the old data and the current settings', () async {
    final out = p.join(dir.path, 'out.sqlite');
    final data = readOldApp(oldAppFile(dir.path), nowMs: 99);
    await writeLedger(out, data, const AppSettings(currencySymbol: r'$', weekStart: 1));

    final schema = AppDatabase(NativeDatabase.memory());
    expect(checkBackupFile(out, schema: schema), isNull);
    await schema.close();

    final db = AppDatabase(NativeDatabase(File(out)));
    final repos = DriftRepositories(db);
    expect((await repos.settings.get()).currencySymbol, r'$');
    expect((await db.select(db.categories).get()).map((c) => c.name), ['Food', 'Salary']);
    expect(await repos.transactions.balanceDeltas(), {1: 100050 + 5000 - 30000 - 101, 2: 30000});
    await db.close();
  });

  testWidgets('Settings imports the old file after showing what it found', (tester) async {
    final app = await pumpApp(tester);
    app.files.nextPick = File(oldAppFile(dir.path)).readAsBytesSync();

    await openTab(tester, 'Settings');
    final tile = find.text('Import from old app (temporary)');
    await tester.scrollUntilVisible(tile, 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(tile);
    for (var i = 0; i < 100 && find.text('Replace').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(find.textContaining('Entries: 1 income, 2 expense, 1 transfers.'), findsOneWidget);
    expect(find.textContaining('Skipped, zero amount: 1 (ids 3)'), findsOneWidget);
    await tapAndSettle(tester, find.text('Replace'));

    expect(app.restorer.restored, endsWith('old_app_import.sqlite'));
    expect(app.restorer.restoredBytes, isNotEmpty);
    expect(Directory(app.files.dir).listSync().map((f) => p.basename(f.path)), isNot(contains('old_app.sqlite')));
  });
}
