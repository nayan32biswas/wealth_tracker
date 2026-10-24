import 'dart:math';

import '../models/enums.dart';
import '../models/transactions.dart';
import '../repositories/repositories.dart';

const _utilitiesFee = 1000;

/// Adds [months] of realistic entries up to [today] for manual testing,
/// next to any data already there. Uses a fixed random seed so the result
/// is always the same.
Future<void> loadDemoData(Repositories repos, DateTime today, {int months = 12}) async {
  final assets = {for (final a in await repos.assets.all()) a.name: a};
  final categories = {for (final c in await repos.categories.all()) '${c.type.name}:${c.name}': c};
  T starter<T>(Map<String, T> items, String key) =>
      items[key] ?? (throw RuleViolation('Demo data needs the starter "${key.split(':').last}" back.'));
  int asset(String name) => starter(assets, name).id;
  int expense(String name) => starter(categories, 'expense:$name').id;
  int income(String name) => starter(categories, 'income:$name').id;

  for (final (name, balance) in [('Cash', 500000), ('Bank Account', 8000000), ('Mobile Wallet', 300000)]) {
    await repos.assets.update(starter(assets, name).copyWith(initialBalance: balance));
  }
  await repos.categories.update(
    starter(categories, 'expense:Utilities').copyWith(feeType: FeeType.fixed, feeValue: _utilitiesFee),
  );

  final random = Random(42);
  final start = DateTime(today.year, today.month - months, today.day);
  final txns = <Transaction>[];

  void add(
    TransactionType type,
    DateTime day,
    int amount,
    String from, {
    int? category,
    String? to,
    int fee = 0,
    String? note,
  }) => txns.add(
    Transaction(
      id: 0,
      type: type,
      amount: amount,
      fee: fee,
      assetId: asset(from),
      toAssetId: to == null ? null : asset(to),
      categoryId: category,
      note: note,
      dateTime: DateTime(day.year, day.month, day.day, 8 + random.nextInt(13), random.nextInt(60)),
    ),
  );

  int taka(int min, int max) => (min + random.nextInt(max - min + 1)) * 100;

  const dailyNotes = ['Lunch', 'Groceries', 'Rickshaw', 'Tea and snacks', null, null];
  var utilityCount = 0;

  for (var day = start; !day.isAfter(today); day = DateTime(day.year, day.month, day.day + 1)) {
    if (day.day == 1) {
      add(TransactionType.income, day, 12000000, 'Bank Account', category: income('Salary'), note: 'Monthly salary');
    }
    for (var n = 0; n < 1 + random.nextInt(3); n++) {
      final category = ['Food', 'Meal', 'Transport'][random.nextInt(3)];
      add(
        TransactionType.expense,
        day,
        taka(40, 900),
        random.nextBool() ? 'Cash' : 'Mobile Wallet',
        category: expense(category),
        note: dailyNotes[random.nextInt(dailyNotes.length)],
      );
    }
    if (day.weekday == DateTime.friday) {
      add(TransactionType.expense, day, taka(1500, 6000), 'Credit Card', category: expense('Shopping'));
    }
    if (day.day == 10) {
      utilityCount++;
      add(
        TransactionType.expense,
        day,
        taka(1800, 3500),
        'Mobile Wallet',
        category: expense('Utilities'),
        fee: utilityCount == 2 ? 500 : _utilitiesFee,
        note: utilityCount == 2 ? 'Fee waived by half this month' : 'Electricity bill',
      );
    }
    if (day.day == 18) {
      add(TransactionType.expense, day, taka(500, 2500), 'Cash', category: expense('Health'), note: 'Pharmacy');
    }
    if (day.day == 7 || day.day == 21) {
      add(TransactionType.transfer, day, 800000, 'Bank Account', to: 'Cash', note: 'ATM withdrawal');
    }
    if (day.day == 12) {
      add(TransactionType.transfer, day, 500000, 'Bank Account', to: 'Mobile Wallet', fee: 9250, note: 'Wallet top-up');
    }
    if (day.day == 25) {
      add(TransactionType.transfer, day, 1000000, 'Bank Account', to: 'Credit Card', note: 'Card bill');
    }
  }

  for (final t in txns) {
    await repos.transactions.save(t);
  }

  final firstRent = DateTime(start.year, start.month + 1, 5);
  await repos.recurring.save(
    RecurringRule(
      id: 0,
      type: TransactionType.expense,
      amount: 2500000,
      assetId: asset('Bank Account'),
      categoryId: expense('Rent'),
      note: 'House rent',
      frequency: Frequency.monthly,
      startDate: firstRent,
      nextDate: firstRent,
    ),
  );
}
