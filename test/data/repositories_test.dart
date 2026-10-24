import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wealthtracker/data/db/app_database.dart';
import 'package:wealthtracker/data/repositories/drift_repositories.dart';
import 'package:wealthtracker/domain/models/app_settings.dart';
import 'package:wealthtracker/domain/models/enums.dart';
import 'package:wealthtracker/domain/models/transactions.dart';
import 'package:wealthtracker/domain/repositories/repositories.dart';
import 'package:wealthtracker/domain/services/reports.dart';
import 'package:wealthtracker/presentation/features/transactions/transaction_draft.dart';

void main() {
  late AppDatabase db;
  late DriftRepositories repos;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory(), clock: () => DateTime(2026, 9, 1));
    repos = DriftRepositories(db);
  });
  tearDown(() => db.close());

  Future<int> assetId(String name) async => (await repos.assets.all()).firstWhere((a) => a.name == name).id;
  Future<int> categoryId(String name, CategoryType type) async =>
      (await repos.categories.all()).firstWhere((c) => c.name == name && c.type == type).id;

  Transaction txn(
    TransactionType type,
    int amount,
    int asset, {
    int fee = 0,
    int? to,
    int? category,
    String? note,
    DateTime? at,
  }) => Transaction(
    id: 0,
    type: type,
    amount: amount,
    fee: fee,
    assetId: asset,
    toAssetId: to,
    categoryId: category,
    note: note,
    dateTime: at ?? DateTime(2026, 9, 10, 12),
  );

  group('asset groups', () {
    test('lists in configured order and follows reorder', () async {
      final ids = (await repos.groups.all()).map((g) => g.id).toList();
      await repos.groups.reorder(ids.reversed.toList());

      expect((await repos.groups.all()).map((g) => g.name), ['Loan', 'Card', 'Mobile Wallet', 'Bank', 'Cash']);
    });

    test('new group goes last with its type', () async {
      await repos.groups.add('Investments', GroupType.asset);

      final last = (await repos.groups.all()).last;
      expect(last.name, 'Investments');
      expect(last.type, GroupType.asset);
    });

    test('cannot remove a group that still has accounts', () async {
      final cash = (await repos.groups.all()).first;

      expect(() => repos.groups.remove(cash.id), throwsA(isA<RuleViolation>()));
    });

    test('an empty group is deleted for good', () async {
      final loan = (await repos.groups.all()).last;
      final account = await repos.assets.add('Car loan', loan.id);
      await repos.assets.remove(account);

      await repos.groups.remove(loan.id);

      expect(await db.select(db.assetGroups).get(), hasLength(4));
    });

    test('a group with an archived account cannot be removed', () async {
      final loan = (await repos.groups.all()).last;
      final account = await repos.assets.add('Car loan', loan.id);
      await repos.transactions.save(txn(TransactionType.income, 500, account));
      await repos.assets.archive(account);

      expect(() => repos.groups.remove(loan.id), throwsA(isA<RuleViolation>()));
    });
  });

  group('assets', () {
    test('removing an account with entries archives it instead of deleting it', () async {
      final wallet = await assetId('Mobile Wallet');
      await repos.transactions.save(txn(TransactionType.income, 500, wallet));

      expect(await repos.assets.usage(wallet), 1);
      expect(await repos.assets.remove(wallet), isFalse);

      expect((await repos.assets.all()).map((a) => a.id), isNot(contains(wallet)));
      expect((await repos.assets.watchArchived().first).map((a) => (a.id, a.isArchived)), [(wallet, true)]);
      expect((await repos.assets.watchNames().first)[wallet], 'Mobile Wallet');
    });

    test('an archived account keeps its money in net worth, even when its old entries change', () async {
      Future<int> netWorth() async => BalanceSheet.from(await repos.groups.all(), [
        ...await repos.assets.all(),
        ...await repos.assets.watchArchived().first,
      ], await repos.transactions.balanceDeltas()).netWorth;
      final (cash, wallet) = (await assetId('Cash'), await assetId('Mobile Wallet'));
      await repos.assets.update(
        (await repos.assets.all()).firstWhere((a) => a.id == wallet).copyWith(initialBalance: 10000),
      );
      final emptied = await repos.transactions.save(txn(TransactionType.transfer, 10000, wallet, to: cash));
      await repos.assets.archive(wallet);
      final before = await netWorth();

      await repos.transactions.delete(emptied);

      expect(await netWorth(), before);
    });

    test('an account only an old removed rule points at is archived, not stuck', () async {
      final (cash, wallet) = (await assetId('Cash'), await assetId('Mobile Wallet'));
      final food = await categoryId('Food', CategoryType.expense);
      final rule = RecurringRule(
        id: 0,
        type: TransactionType.expense,
        amount: 100,
        assetId: wallet,
        categoryId: food,
        frequency: Frequency.monthly,
        startDate: DateTime(2026, 9, 1),
        nextDate: DateTime(2026, 9, 1),
      );
      final ruleId = await repos.recurring.save(rule);
      await repos.recurring.applyOccurrences(rule.copyWith(id: ruleId), [DateTime(2026, 9, 1)], DateTime(2026, 10, 1));
      final entry = (await repos.transactions.find(const TransactionQuery())).single;
      await repos.transactions.save(entry.copyWith(assetId: cash));
      await repos.recurring.remove(ruleId);

      expect(await repos.assets.usage(wallet), 0);
      expect(await repos.assets.remove(wallet), isFalse);
      expect((await repos.assets.watchArchived().first).map((a) => a.id), [wallet]);
    });

    test('moving an account to another group keeps its balance', () async {
      final wallet = (await repos.assets.all()).firstWhere((a) => a.name == 'Mobile Wallet');
      final bank = (await repos.groups.all()).firstWhere((g) => g.name == 'Bank');
      await repos.assets.update(wallet.copyWith(groupId: bank.id, initialBalance: 700));

      final moved = (await repos.assets.all()).firstWhere((a) => a.id == wallet.id);
      expect((moved.groupId, moved.initialBalance), (bank.id, 700));
    });

    test('unarchive brings the account back to the list', () async {
      final wallet = await assetId('Mobile Wallet');
      await repos.transactions.save(txn(TransactionType.income, 500, wallet));
      await repos.assets.archive(wallet);

      await repos.assets.unarchive(wallet);

      expect((await repos.assets.all()).map((a) => a.id), contains(wallet));
      expect(await repos.assets.watchArchived().first, isEmpty);
    });

    test('an account no entry uses is deleted for good, even with an opening balance', () async {
      final wallet = await assetId('Mobile Wallet');
      await repos.assets.update(
        (await repos.assets.all()).firstWhere((a) => a.id == wallet).copyWith(initialBalance: 900),
      );

      expect(await repos.assets.usage(wallet), 0);
      await repos.assets.remove(wallet);

      expect((await repos.assets.watchNames().first)[wallet], isNull);
    });

    test('transfers in and out both count as using the account', () async {
      final (cash, wallet) = (await assetId('Cash'), await assetId('Mobile Wallet'));
      await repos.transactions.save(txn(TransactionType.transfer, 500, cash, to: wallet));
      await repos.transactions.save(txn(TransactionType.transfer, 500, wallet, to: cash));

      expect(await repos.assets.usage(wallet), 2);
    });

    test('cannot remove an account that an active recurring rule still uses', () async {
      final wallet = await assetId('Mobile Wallet');
      await repos.recurring.save(
        RecurringRule(
          id: 0,
          type: TransactionType.expense,
          amount: 100,
          assetId: wallet,
          categoryId: await categoryId('Food', CategoryType.expense),
          frequency: Frequency.monthly,
          startDate: DateTime(2026, 10, 1),
          nextDate: DateTime(2026, 10, 1),
        ),
      );

      expect(() => repos.assets.remove(wallet), throwsA(isA<RuleViolation>()));
      expect(() => repos.assets.archive(wallet), throwsA(isA<RuleViolation>()));
    });

    test('a paused recurring rule also blocks removing its account', () async {
      final wallet = await assetId('Mobile Wallet');
      await repos.recurring.save(
        RecurringRule(
          id: 0,
          type: TransactionType.expense,
          amount: 100,
          assetId: wallet,
          categoryId: await categoryId('Food', CategoryType.expense),
          frequency: Frequency.monthly,
          startDate: DateTime(2026, 10, 1),
          nextDate: DateTime(2026, 10, 1),
          isActive: false,
        ),
      );

      expect(() => repos.assets.remove(wallet), throwsA(isA<RuleViolation>()));
    });

    test('a removed recurring rule no longer blocks removing its account', () async {
      final wallet = await assetId('Mobile Wallet');
      final ruleId = await repos.recurring.save(
        RecurringRule(
          id: 0,
          type: TransactionType.expense,
          amount: 100,
          assetId: wallet,
          categoryId: await categoryId('Food', CategoryType.expense),
          frequency: Frequency.monthly,
          startDate: DateTime(2026, 10, 1),
          nextDate: DateTime(2026, 10, 1),
        ),
      );
      await repos.recurring.remove(ruleId);

      expect(await repos.assets.remove(wallet), isTrue);
      expect((await repos.assets.all()).map((a) => a.id), isNot(contains(wallet)));
      // The rule never made an entry, so it went too and the account is gone for good.
      expect(await db.select(db.recurringRules).get(), isEmpty);
      expect((await repos.assets.watchNames().first)[wallet], isNull);
    });

    test('an account with zero balance can be removed', () async {
      final wallet = await assetId('Mobile Wallet');
      await repos.assets.remove(wallet);

      expect((await repos.assets.all()).map((a) => a.name), isNot(contains('Mobile Wallet')));
    });

    test('update keeps new name and opening balance', () async {
      final cash = (await repos.assets.all()).first;
      await repos.assets.update(cash.copyWith(name: 'Wallet', initialBalance: 1000));

      final updated = (await repos.assets.all()).first;
      expect(updated.name, 'Wallet');
      expect(updated.initialBalance, 1000);
    });
  });

  group('categories', () {
    test('a category with entries is only marked deleted, so old entries still show it', () async {
      final food = await categoryId('Food', CategoryType.expense);
      await repos.transactions.save(txn(TransactionType.expense, 100, await assetId('Cash'), category: food));

      expect(await repos.categories.usage(food), 1);
      await repos.categories.remove(food);

      expect((await repos.categories.all()).map((c) => c.id), isNot(contains(food)));
      expect((await repos.categories.watchNames().first)[food], 'Food');
    });

    test('a category nothing uses is deleted for good', () async {
      final food = await categoryId('Food', CategoryType.expense);

      expect(await repos.categories.usage(food), 0);
      await repos.categories.remove(food);

      expect((await repos.categories.watchNames().first)[food], isNull);
    });

    test('a category a recurring rule uses is only marked deleted', () async {
      final food = await categoryId('Food', CategoryType.expense);
      await repos.recurring.save(
        RecurringRule(
          id: 0,
          type: TransactionType.expense,
          amount: 100,
          assetId: await assetId('Cash'),
          categoryId: food,
          frequency: Frequency.monthly,
          startDate: DateTime(2026, 10, 1),
          nextDate: DateTime(2026, 10, 1),
        ),
      );
      await repos.categories.remove(food);

      expect((await repos.categories.watchNames().first)[food], 'Food');
    });

    test('merge moves entries and recurring rules, then deletes the category for good', () async {
      final (food, rent) = (
        await categoryId('Food', CategoryType.expense),
        await categoryId('Rent', CategoryType.expense),
      );
      final cash = await assetId('Cash');
      final entry = await repos.transactions.save(txn(TransactionType.expense, -100, cash, category: food));
      final rule = await repos.recurring.save(
        RecurringRule(
          id: 0,
          type: TransactionType.expense,
          amount: 100,
          assetId: cash,
          categoryId: food,
          frequency: Frequency.monthly,
          startDate: DateTime(2026, 10, 1),
          nextDate: DateTime(2026, 10, 1),
        ),
      );

      await repos.categories.merge(food, rent);

      final moved = (await repos.transactions.byId(entry))!;
      expect((moved.categoryId, moved.amount), (rent, -100));
      expect((await repos.recurring.active()).singleWhere((r) => r.id == rule).categoryId, rent);
      expect((await repos.categories.watchNames().first)[food], isNull);
    });

    test('merge refuses a category of the other type or itself', () async {
      final food = await categoryId('Food', CategoryType.expense);
      final salary = await categoryId('Salary', CategoryType.income);

      expect(() => repos.categories.merge(food, salary), throwsA(isA<RuleViolation>()));
      expect(() => repos.categories.merge(food, food), throwsA(isA<RuleViolation>()));
    });

    test('stores default fee settings', () async {
      final fees = (await repos.categories.all()).firstWhere((c) => c.name == 'Bank Charges');
      await repos.categories.update(fees.copyWith(feeType: FeeType.percent, feeValue: 185));

      final saved = (await repos.categories.all()).firstWhere((c) => c.id == fees.id);
      expect(saved.feeType, FeeType.percent);
      expect(saved.feeValue, 185);
    });

    test('removed categories are hidden', () async {
      final food = await categoryId('Food', CategoryType.expense);
      await repos.categories.remove(food);

      expect((await repos.categories.all()).map((c) => c.id), isNot(contains(food)));
    });
  });

  group('restoring deleted items', () {
    test('a category marked deleted is listed, and restore brings it back at the end', () async {
      final food = await categoryId('Food', CategoryType.expense);
      await repos.transactions.save(txn(TransactionType.expense, 100, await assetId('Cash'), category: food));
      await repos.categories.remove(food);

      expect((await repos.categories.watchDeleted().first).map((c) => c.name), ['Food']);

      await repos.categories.restore(food);

      expect(await repos.categories.watchDeleted().first, isEmpty);
      expect((await repos.categories.all()).last.id, food);
    });
  });

  group('transactions', () {
    test('save inserts then updates the same row', () async {
      final cash = await assetId('Cash');
      final id = await repos.transactions.save(txn(TransactionType.expense, 100, cash, note: 'tea'));
      await repos.transactions.save((await repos.transactions.byId(id))!.copyWith(amount: 150));

      final saved = await repos.transactions.byId(id);
      expect(saved!.amount, 150);
      expect(saved.note, 'tea');
      expect(await repos.transactions.find(const TransactionQuery()), hasLength(1));
    });

    test('query filters by date range, text, type, account and category', () async {
      final cash = await assetId('Cash');
      final bank = await assetId('Bank Account');
      final food = await categoryId('Food', CategoryType.expense);
      await repos.transactions.save(
        txn(TransactionType.expense, 100, cash, category: food, note: 'Lunch at office', at: DateTime(2026, 9, 5)),
      );
      await repos.transactions.save(txn(TransactionType.income, 900, bank, at: DateTime(2026, 9, 6)));
      await repos.transactions.save(txn(TransactionType.transfer, 50, bank, to: cash, at: DateTime(2026, 9, 7)));
      await repos.transactions.save(txn(TransactionType.expense, 70, cash, at: DateTime(2026, 10, 1)));

      Future<List<int>> amounts(TransactionQuery q) async =>
          (await repos.transactions.find(q)).map((t) => t.amount).toList();

      expect(await amounts(TransactionQuery(from: DateTime(2026, 9), toExclusive: DateTime(2026, 10))), [50, 900, 100]);
      expect(await amounts(const TransactionQuery(text: 'lunch')), [100]);
      expect(await amounts(const TransactionQuery(types: {TransactionType.income})), [900]);
      expect(await amounts(TransactionQuery(assetIds: {cash})), [70, 50, 100]);
      expect(await amounts(TransactionQuery(categoryIds: {food})), [100]);
      expect(await amounts(const TransactionQuery(limit: 2)), [70, 50]);
    });

    test('query matches any of several accounts or categories', () async {
      final cash = await assetId('Cash');
      final bank = await assetId('Bank Account');
      final wallet = await assetId('Mobile Wallet');
      final card = await assetId('Credit Card');
      final food = await categoryId('Food', CategoryType.expense);
      final transport = await categoryId('Transport', CategoryType.expense);
      final health = await categoryId('Health', CategoryType.expense);
      await repos.transactions.save(txn(TransactionType.expense, 1, cash, category: food, at: DateTime(2026, 9, 1)));
      await repos.transactions.save(
        txn(TransactionType.expense, 2, card, category: transport, at: DateTime(2026, 9, 2)),
      );
      await repos.transactions.save(
        txn(TransactionType.expense, 3, wallet, category: health, at: DateTime(2026, 9, 3)),
      );
      await repos.transactions.save(txn(TransactionType.transfer, 4, bank, to: wallet, at: DateTime(2026, 9, 4)));

      Future<List<int>> amounts(TransactionQuery q) async =>
          (await repos.transactions.find(q)).map((t) => t.amount).toList();

      expect(await amounts(TransactionQuery(categoryIds: {food, transport})), [2, 1]);
      expect(await amounts(TransactionQuery(assetIds: {cash, wallet})), [4, 3, 1]);
      expect(await amounts(const TransactionQuery(categoryIds: {}, assetIds: {})), [4, 3, 2, 1]);
    });

    test('query sorts by the money moved, fees included', () async {
      final cash = await assetId('Cash');
      final bank = await assetId('Bank Account');
      // Moved: expense 100 + 50 = 150, income 300 - 200 = 100, transfer 120 + 0.
      await repos.transactions.save(txn(TransactionType.expense, 100, cash, fee: 50, at: DateTime(2026, 9, 1)));
      await repos.transactions.save(txn(TransactionType.income, 300, bank, fee: 200, at: DateTime(2026, 9, 2)));
      await repos.transactions.save(txn(TransactionType.transfer, 120, bank, to: cash, at: DateTime(2026, 9, 3)));

      Future<List<int>> totals(TransactionSort sort, {int? limit}) async =>
          (await repos.transactions.find(TransactionQuery(sort: sort, limit: limit))).map((t) => t.total).toList();

      expect(await totals(TransactionSort.newest), [120, 100, 150]);
      expect(await totals(TransactionSort.largest), [150, 120, 100]);
      expect(await totals(TransactionSort.smallest), [100, 120, 150]);
      expect(await totals(TransactionSort.largest, limit: 1), [150]);
    });

    test('search treats % and _ as plain characters', () async {
      final cash = await assetId('Cash');
      for (final (amount, note) in [(1, 'a_b'), (2, 'axb'), (3, '50% off'), (4, '500 off')]) {
        await repos.transactions.save(txn(TransactionType.expense, amount, cash, note: note));
      }

      Future<List<String?>> notes(String text) async =>
          (await repos.transactions.find(TransactionQuery(text: text))).map((t) => t.note).toList();

      expect(await notes('a_b'), ['a_b']);
      expect(await notes('50%'), ['50% off']);
    });

    test('balance deltas follow the balance rule', () async {
      final cash = await assetId('Cash');
      final bank = await assetId('Bank Account');
      final card = await assetId('Credit Card');
      await repos.transactions.save(txn(TransactionType.income, 10000, bank, fee: 500));
      await repos.transactions.save(txn(TransactionType.expense, 2000, card, fee: 30));
      await repos.transactions.save(txn(TransactionType.transfer, 3000, bank, to: cash, fee: 10));

      final deltas = await repos.transactions.watchBalanceDeltas().first;
      expect(deltas[bank], 10000 - 500 - 3000 - 10);
      expect(deltas[cash], 3000);
      expect(deltas[card], -2030);
    });

    test('a negative income or expense is stored and moves the balance the other way', () async {
      final cash = await assetId('Cash');
      final bank = await assetId('Bank Account');
      await repos.transactions.save(txn(TransactionType.expense, -2000, cash, fee: 30));
      await repos.transactions.save(txn(TransactionType.income, -500, bank));

      final deltas = await repos.transactions.watchBalanceDeltas().first;
      expect(deltas[cash], 2000 - 30);
      expect(deltas[bank], -500);
    });

    test('a zero amount or a negative transfer is refused', () async {
      final cash = await assetId('Cash');
      final bank = await assetId('Bank Account');

      expect(repos.transactions.save(txn(TransactionType.expense, 0, cash)), throwsA(isA<SqliteException>()));
      expect(
        repos.transactions.save(txn(TransactionType.transfer, -100, bank, to: cash)),
        throwsA(isA<SqliteException>()),
      );
    });

    test('monthly flows sum income, expense and net-worth change', () async {
      final cash = await assetId('Cash');
      final bank = await assetId('Bank Account');
      await repos.transactions.save(txn(TransactionType.income, 1000, bank, fee: 100, at: DateTime(2026, 8, 3)));
      await repos.transactions.save(txn(TransactionType.expense, 200, cash, fee: 5, at: DateTime(2026, 8, 20)));
      await repos.transactions.save(
        txn(TransactionType.transfer, 300, bank, to: cash, fee: 7, at: DateTime(2026, 9, 1)),
      );

      final flows = await repos.transactions.watchMonthlyFlows().first;
      expect(flows.map((f) => f.month), ['2026-08', '2026-09']);
      expect(flows[0].income, 900);
      expect(flows[0].expense, 205);
      expect(flows[0].netChange, 695);
      expect(flows[1].income, 0);
      expect(flows[1].netChange, -7);
    });

    test(
      'totals take income after its fee and expense with its fee, leave out transfers, and follow the filter',
      () async {
        final cash = await assetId('Cash');
        final bank = await assetId('Bank Account');
        await repos.transactions.save(txn(TransactionType.income, 1000, bank, fee: 50, note: 'pay'));
        await repos.transactions.save(txn(TransactionType.expense, 300, cash, fee: 10, note: 'lunch'));
        await repos.transactions.save(txn(TransactionType.transfer, 500, bank, fee: 5, to: cash, note: 'atm'));

        expect(await repos.transactions.watchTotals(const TransactionQuery(limit: 1)).first, (
          income: 950,
          expense: 310,
        ));
        expect(await repos.transactions.watchTotals(const TransactionQuery(text: 'lunch')).first, (
          income: 0,
          expense: 310,
        ));
        expect(await repos.transactions.watchTotals(const TransactionQuery(text: 'none')).first, (
          income: 0,
          expense: 0,
        ));
      },
    );

    test('delete removes the row', () async {
      final cash = await assetId('Cash');
      final id = await repos.transactions.save(txn(TransactionType.expense, 100, cash));
      await repos.transactions.delete(id);

      expect(await repos.transactions.hasAny(), isFalse);
    });
  });

  group('note suggestions', () {
    final since = DateTime(2025, 9, 1);

    Future<void> notes(List<(String?, int?, DateTime)> entries) async {
      final cash = await assetId('Cash');
      for (final (note, category, at) in entries) {
        await repos.transactions.save(txn(TransactionType.expense, 100, cash, category: category, note: note, at: at));
      }
    }

    test('notes used with the category come first, then the most used, then the newest', () async {
      final food = await categoryId('Food', CategoryType.expense);
      await notes([
        ('Rickshaw', null, DateTime(2026, 9, 1)),
        ('Rickshaw', null, DateTime(2026, 9, 2)),
        ('Tea', null, DateTime(2026, 9, 3)),
        ('Pharmacy', null, DateTime(2026, 9, 4)),
        ('Lunch', food, DateTime(2026, 8, 1)),
      ]);

      expect(await repos.transactions.noteSuggestions(since: since), ['Rickshaw', 'Pharmacy', 'Tea', 'Lunch']);
      expect(await repos.transactions.noteSuggestions(since: since, categoryId: food), [
        'Lunch',
        'Rickshaw',
        'Pharmacy',
        'Tea',
      ]);
    });

    test('the same note in another case counts once, spelled as last typed', () async {
      await notes([
        ('lunch', null, DateTime(2026, 9, 1)),
        ('Lunch ', null, DateTime(2026, 9, 5)),
        ('Tea', null, DateTime(2026, 9, 3)),
      ]);

      expect(await repos.transactions.noteSuggestions(since: since), ['Lunch', 'Tea']);
    });

    test('matches the start of the note or of any word in it, but not the exact note', () async {
      await notes([
        ('Rickshaw', null, DateTime(2026, 9, 1)),
        ('CNG rickshaw', null, DateTime(2026, 9, 2)),
        ('Brick', null, DateTime(2026, 9, 3)),
      ]);

      expect(await repos.transactions.noteSuggestions(text: 'ric', since: since), ['CNG rickshaw', 'Rickshaw']);
      expect(await repos.transactions.noteSuggestions(text: 'rickshaw', since: since), ['CNG rickshaw']);
    });

    test('% and _ are plain characters', () async {
      await notes([('50% off', null, DateTime(2026, 9, 1)), ('500 taka', null, DateTime(2026, 9, 2))]);

      expect(await repos.transactions.noteSuggestions(text: '50%', since: since), ['50% off']);
      expect(await repos.transactions.noteSuggestions(text: '_', since: since), isEmpty);
    });

    test('skips blank notes, notes before the cut-off and notes of deleted entries', () async {
      await notes([
        (null, null, DateTime(2026, 9, 1)),
        ('   ', null, DateTime(2026, 9, 1)),
        ('Old habit', null, DateTime(2025, 8, 31)),
        ('Gone', null, DateTime(2026, 9, 1)),
        ('Tea', null, DateTime(2026, 9, 1)),
      ]);
      final gone = (await repos.transactions.find(const TransactionQuery(text: 'Gone'))).single;
      await repos.transactions.delete(gone.id);

      expect(await repos.transactions.noteSuggestions(since: since), ['Tea']);
    });

    test('returns at most the limit', () async {
      await notes([for (var i = 0; i < 10; i++) ('Note $i', null, DateTime(2026, 9, 1 + i))]);

      expect(await repos.transactions.noteSuggestions(since: since, limit: 3), ['Note 9', 'Note 8', 'Note 7']);
    });
  });

  group('recurring rules', () {
    Future<RecurringRule> savedRule() async {
      final bank = await assetId('Bank Account');
      final rent = await categoryId('Rent', CategoryType.expense);
      final id = await repos.recurring.save(
        RecurringRule(
          id: 0,
          type: TransactionType.expense,
          amount: 15000,
          assetId: bank,
          categoryId: rent,
          note: 'Rent',
          frequency: Frequency.monthly,
          startDate: DateTime(2026, 7, 1),
          nextDate: DateTime(2026, 7, 1),
        ),
      );
      return (await repos.recurring.active()).firstWhere((r) => r.id == id);
    }

    test('applying occurrences creates transactions and moves next date', () async {
      final rule = await savedRule();
      await repos.recurring.applyOccurrences(rule, [DateTime(2026, 7, 1), DateTime(2026, 8, 1)], DateTime(2026, 9, 1));

      final created = await repos.transactions.find(const TransactionQuery());
      expect(created.map((t) => t.dateTime), [DateTime(2026, 8, 1), DateTime(2026, 7, 1)]);
      expect(created.every((t) => t.recurringRuleId == rule.id), isTrue);
      expect((await repos.recurring.active()).single.nextDate, DateTime(2026, 9, 1));
    });

    test('applying the same date twice creates it once', () async {
      final rule = await savedRule();
      await repos.recurring.applyOccurrences(rule, [DateTime(2026, 7, 1)], DateTime(2026, 8, 1));
      await repos.recurring.applyOccurrences(rule, [DateTime(2026, 7, 1)], DateTime(2026, 8, 1));

      expect(await repos.transactions.find(const TransactionQuery()), hasLength(1));
    });

    test('an entry moved to another day no longer stops the rule paying on that day', () async {
      final rule = await savedRule();
      await repos.recurring.applyOccurrences(rule, [DateTime(2026, 7, 1)], DateTime(2026, 8, 1));
      final first = (await repos.transactions.find(const TransactionQuery())).single;
      await repos.transactions.save(TransactionDraft.edit(first).withDateTime(DateTime(2026, 8, 1, 9)).toTransaction());

      await repos.recurring.applyOccurrences(rule, [DateTime(2026, 8, 1)], DateTime(2026, 9, 1));

      expect(await repos.transactions.find(const TransactionQuery()), hasLength(2));
    });

    test('removed rules are no longer active', () async {
      final rule = await savedRule();
      await repos.recurring.remove(rule.id);

      expect(await repos.recurring.active(), isEmpty);
    });
  });

  group('settings', () {
    test('defaults come from the seed and saves round-trip', () async {
      expect((await repos.settings.get()).currencyCode, 'BDT');

      await repos.settings.save(const AppSettings(currencySymbol: r'$', currencyCode: 'USD'));

      final saved = await repos.settings.get();
      expect(saved.currencyCode, 'USD');
    });
  });
}
