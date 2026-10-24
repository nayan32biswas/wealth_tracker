import 'package:drift/native.dart';
import 'package:flutter/material.dart' show DateUtils;
import 'package:flutter_test/flutter_test.dart';
import 'package:wealthtracker/data/db/app_database.dart';
import 'package:wealthtracker/data/repositories/drift_repositories.dart';
import 'package:wealthtracker/domain/models/accounts.dart';
import 'package:wealthtracker/domain/models/enums.dart';
import 'package:wealthtracker/domain/models/transactions.dart';
import 'package:wealthtracker/domain/repositories/repositories.dart';
import 'package:wealthtracker/domain/services/demo_data.dart';

void main() {
  final today = DateTime(2026, 9, 23);
  late AppDatabase db;
  late DriftRepositories repos;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repos = DriftRepositories(db);
  });
  tearDown(() => db.close());

  int expectedDelta(List<Transaction> txns, int assetId) {
    var sum = 0;
    for (final t in txns) {
      if (t.assetId == assetId) sum += t.type == TransactionType.income ? t.amount - t.fee : -(t.amount + t.fee);
      if (t.toAssetId == assetId) sum += t.amount;
    }
    return sum;
  }

  test('produces the same data every time', () async {
    await loadDemoData(repos, today);
    final first = await repos.transactions.find(const TransactionQuery());

    final otherDb = AppDatabase(NativeDatabase.memory());
    addTearDown(otherDb.close);
    final other = DriftRepositories(otherDb);
    await loadDemoData(other, today);
    final second = await other.transactions.find(const TransactionQuery());

    expect(second.map((t) => (t.amount, t.fee, t.dateTime)), first.map((t) => (t.amount, t.fee, t.dateTime)));
  });

  test('covers 12 months up to today by default, with every kind of entry', () async {
    await loadDemoData(repos, today);
    final txns = await repos.transactions.find(const TransactionQuery());

    final dates = txns.map((t) => t.dateTime).toList()..sort();
    expect(DateUtils.dateOnly(dates.first), DateTime(2025, 9, 23));
    expect(DateUtils.dateOnly(dates.last), today);
    expect(txns.map((t) => t.type).toSet(), TransactionType.values.toSet());
    expect(txns.where((t) => t.fee > 0), isNotEmpty);
    expect(txns.where((t) => t.note?.isNotEmpty ?? false), isNotEmpty);
    expect(await repos.recurring.active(), hasLength(1));
    expect((await repos.categories.all()).where((c) => c.feeType != FeeType.none), isNotEmpty);
  });

  test('balances match the rule and the credit card owes money', () async {
    await loadDemoData(repos, today);
    final txns = await repos.transactions.find(const TransactionQuery());
    final deltas = await repos.transactions.watchBalanceDeltas().first;

    for (final asset in await repos.assets.all()) {
      expect(deltas[asset.id] ?? 0, expectedDelta(txns, asset.id), reason: asset.name);
    }
    final card = (await repos.assets.all()).firstWhere((a) => a.name == 'Credit Card');
    expect(card.initialBalance + (deltas[card.id] ?? 0), isNegative);
  });

  test('covers the chosen number of months', () async {
    await loadDemoData(repos, today, months: 2);
    final dates = (await repos.transactions.find(const TransactionQuery())).map((t) => t.dateTime).toList()..sort();

    expect(DateUtils.dateOnly(dates.first), DateTime(2026, 7, 23));
    expect(DateUtils.dateOnly(dates.last), today);
  });

  test('adds to a ledger that already has entries', () async {
    await loadDemoData(repos, today, months: 1);
    final before = await repos.transactions.find(const TransactionQuery());

    await loadDemoData(repos, today, months: 1);

    final after = await repos.transactions.find(const TransactionQuery());
    expect(after, hasLength(before.length * 2));
    expect(after.map((t) => t.id), containsAll(before.map((t) => t.id)));
  });

  test('still needs the starter accounts when adding to existing data', () async {
    final cash = (await repos.assets.all()).firstWhere((a) => a.name == 'Cash');
    await repos.assets.update(cash.copyWith(name: 'Wallet'));

    await expectLater(
      loadDemoData(repos, today, months: 1),
      throwsA(isA<RuleViolation>().having((e) => e.message, 'message', 'Demo data needs the starter "Cash" back.')),
    );
  });

  test('a failure inside a transaction leaves the ledger as it was', () async {
    await expectLater(
      repos.inTransaction(() async {
        await loadDemoData(repos, today, months: 1);
        throw const RuleViolation('stop');
      }),
      throwsA(isA<RuleViolation>()),
    );

    expect(await repos.transactions.hasAny(), isFalse);
  });

  test('reset brings back the starter ledger and keeps the settings', () async {
    final fresh = DriftRepositories(AppDatabase(NativeDatabase.memory()));
    await loadDemoData(repos, today, months: 1);
    final cash = (await repos.assets.all()).firstWhere((a) => a.name == 'Cash');
    await repos.assets.update(cash.copyWith(name: 'Wallet'));
    await repos.settings.save((await repos.settings.get()).copyWith(currencyCode: 'USD'));

    await repos.resetToStarter();

    expect(await repos.transactions.hasAny(), isFalse);
    expect(await repos.recurring.active(), isEmpty);
    List<(String, int)> accounts(List<Asset> all) => [for (final a in all) (a.name, a.initialBalance)];
    expect(accounts(await repos.assets.all()), accounts(await fresh.assets.all()));
    expect(
      (await repos.categories.all()).map((c) => (c.name, c.type, c.feeType)),
      (await fresh.categories.all()).map((c) => (c.name, c.type, c.feeType)),
    );
    expect((await repos.groups.all()).map((g) => g.name), (await fresh.groups.all()).map((g) => g.name));
    expect((await repos.settings.get()).currencyCode, 'USD');
  });
}
