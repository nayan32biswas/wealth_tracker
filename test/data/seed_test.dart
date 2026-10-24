import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wealthtracker/data/db/app_database.dart';

void main() {
  test('first launch seeds groups, accounts, categories and settings', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    final groups = await (db.select(db.assetGroups)..orderBy([(g) => OrderingTerm(expression: g.sortOrder)])).get();
    expect(groups.map((g) => g.name), ['Cash', 'Bank', 'Mobile Wallet', 'Card', 'Loan']);
    expect(groups.where((g) => g.type == 'liability').map((g) => g.name), ['Card', 'Loan']);

    final assets = await db.select(db.assets).get();
    expect(assets.map((a) => a.name), ['Cash', 'Bank Account', 'Mobile Wallet', 'Credit Card']);
    expect(assets.every((a) => a.initialBalance == 0), isTrue);

    final categories = await db.select(db.categories).get();
    expect(categories.where((c) => c.type == 'expense'), hasLength(12));
    expect(categories.where((c) => c.type == 'income'), hasLength(6));
    expect(categories.every((c) => c.feeType == 'none'), isTrue);

    final settings = {for (final s in await db.select(db.settings).get()) s.key: s.value};
    expect(settings['currency_symbol'], '৳');
    expect(settings['currency_code'], 'BDT');
    expect(settings['week_start'], '${DateTime.saturday}');
  });

  test('reopening an existing database does not seed again', () async {
    final dir = await Directory.systemTemp.createTemp('wt_seed');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/app.sqlite');

    final first = AppDatabase(NativeDatabase(file));
    await first.select(first.assetGroups).get();
    await first.close();

    final second = AppDatabase(NativeDatabase(file));
    addTearDown(second.close);
    expect(await second.select(second.assetGroups).get(), hasLength(5));
    expect(await second.select(second.categories).get(), hasLength(18));
  });

  test('foreign keys are enforced', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    await expectLater(
      db.into(db.assets).insert(AssetsCompanion.insert(name: 'Orphan', assetGroupId: 999, createdAt: 0, updatedAt: 0)),
      throwsA(isA<SqliteException>()),
    );
  });
}
