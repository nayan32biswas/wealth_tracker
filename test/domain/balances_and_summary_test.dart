import 'package:flutter_test/flutter_test.dart';
import 'package:wealthtracker/domain/models/accounts.dart';
import 'package:wealthtracker/domain/models/enums.dart';
import 'package:wealthtracker/domain/models/transactions.dart';
import 'package:wealthtracker/domain/services/calendar.dart';
import 'package:wealthtracker/domain/services/reports.dart';

void main() {
  group('balances', () {
    const groups = [
      AssetGroup(id: 1, name: 'Cash', type: GroupType.asset),
      AssetGroup(id: 2, name: 'Card', type: GroupType.liability),
    ];
    const assets = [
      Asset(id: 10, name: 'Wallet', groupId: 1, initialBalance: 1000),
      Asset(id: 11, name: 'Bank', groupId: 1),
      Asset(id: 20, name: 'Visa', groupId: 2),
    ];

    test('an account that is no longer on the sheet has no balance', () {
      final sheet = BalanceSheet.from(groups, assets, const {});

      expect(sheet.balanceOf(999), isNull);
    });

    test('adds opening balance and deltas per account', () {
      final sheet = BalanceSheet.from(groups, assets, {10: 500, 20: -3000});

      expect(sheet.balanceOf(10), 1500);
      expect(sheet.balanceOf(11), 0);
      expect(sheet.balanceOf(20), -3000);
    });

    test('liabilities are shown as owed and lower net worth', () {
      final sheet = BalanceSheet.from(groups, assets, {10: 500, 20: -3000});

      expect(sheet.assets, 1500);
      expect(sheet.liabilities, 3000);
      expect(sheet.netWorth, -1500);
    });

    test('groups carry their accounts and subtotal in order', () {
      final sheet = BalanceSheet.from(groups, assets, {10: 500, 11: 200, 20: -3000});

      expect(sheet.groups.map((g) => g.group.name), ['Cash', 'Card']);
      expect(sheet.groups.first.accounts.map((a) => a.asset.name), ['Wallet', 'Bank']);
      expect(sheet.groups.first.total, 1700);
      expect(sheet.groups.last.total, -3000);
    });

    test('a card paid off beyond its debt counts as an asset-side credit', () {
      final sheet = BalanceSheet.from(groups, assets, {20: 400});

      expect(sheet.liabilities, -400);
      expect(sheet.netWorth, 1400);
    });
  });

  group('net-worth trend', () {
    test('works back from today so each month end is today minus later changes', () {
      final trend = netWorthTrend(
        current: 10300,
        flows: const [
          MonthlyFlow(month: '2026-06', income: 0, expense: 0, netChange: 500),
          MonthlyFlow(month: '2026-08', income: 0, expense: 0, netChange: -200),
        ],
        months: ['2026-07', '2026-08', '2026-09'],
      );

      expect(trend, [10500, 10300, 10300]);
    });
  });

  group('account totals', () {
    Transaction t(TransactionType type, int amount, {int fee = 0, int from = 1, int? to}) => Transaction(
      id: 0,
      type: type,
      amount: amount,
      fee: fee,
      assetId: from,
      toAssetId: to,
      dateTime: DateTime(2026, 9, 1),
    );

    test('income arrives with its fee taken off; expenses cost amount plus fee', () {
      final totals = AccountTotals.of([
        t(TransactionType.income, 1000, fee: 100),
        t(TransactionType.expense, 300, fee: 20),
      ], 1);

      expect((totals.inflow, totals.outflow, totals.net), (900, 320, 580));
    });

    test('a transfer out costs amount plus fee, and the other side gets the amount', () {
      final transfer = t(TransactionType.transfer, 500, fee: 10, from: 1, to: 2);

      final source = AccountTotals.of([transfer], 1);
      final target = AccountTotals.of([transfer], 2);

      expect((source.inflow, source.outflow, source.net), (0, 510, -510));
      expect((target.inflow, target.outflow, target.net), (500, 0, 500));
    });

    test('entries of other accounts are ignored', () {
      final totals = AccountTotals.of([t(TransactionType.income, 1000, from: 3)], 1);

      expect((totals.inflow, totals.outflow), (0, 0));
    });
  });

  group('trend windows', () {
    final today = DateTime(2026, 9, 23);
    const flows = [
      MonthlyFlow(month: '2024-03', income: 1000, expense: 400, netChange: 600),
      MonthlyFlow(month: '2025-11', income: 300, expense: 100, netChange: 200),
      MonthlyFlow(month: '2026-02', income: 500, expense: 200, netChange: 300),
      MonthlyFlow(month: '2026-09', income: 700, expense: 50, netChange: 650),
    ];

    List<TrendPoint> points(TrendScale scale, int stepsBack) =>
        trendPoints(scale: scale, today: today, stepsBack: stepsBack, currentNetWorth: 10000, flows: flows);

    test('monthly ends at this month with six columns, empty months at zero', () {
      final p = points(TrendScale.month, 0);

      expect(p.map((x) => x.start), [for (var m = 4; m <= 9; m++) DateTime(2026, m)]);
      expect(p.map((x) => x.income), [0, 0, 0, 0, 0, 700]);
      expect(p.map((x) => x.expense), [0, 0, 0, 0, 0, 50]);
      expect(p.map((x) => x.netWorth), [9350, 9350, 9350, 9350, 9350, 10000]);
    });

    test('one step back moves the monthly window one month older', () {
      final p = points(TrendScale.month, 1);

      expect(p.first.start, DateTime(2026, 3));
      expect(p.last.start, DateTime(2026, 8));
    });

    test('a monthly window can cross into the year before', () {
      final p = points(TrendScale.month, 6);

      expect(p.map((x) => x.start), [
        DateTime(2025, 10),
        DateTime(2025, 11),
        DateTime(2025, 12),
        DateTime(2026, 1),
        DateTime(2026, 2),
        DateTime(2026, 3),
      ]);
      expect(p.map((x) => x.income), [0, 300, 0, 0, 500, 0]);
      expect(p.map((x) => x.netWorth), [8850, 9050, 9050, 9050, 9350, 9350]);
    });

    test('yearly adds up the months and takes net worth at the end of each year', () {
      final p = points(TrendScale.year, 0);

      expect(p.map((x) => x.start), [for (var y = 2021; y <= 2026; y++) DateTime(y)]);
      expect(p.map((x) => x.income), [0, 0, 0, 1000, 300, 1200]);
      expect(p.map((x) => x.expense), [0, 0, 0, 400, 100, 250]);
      expect(p.map((x) => x.netWorth), [8250, 8250, 8250, 8850, 9050, 10000]);
    });

    test('one step back moves the yearly window one year older', () {
      final p = points(TrendScale.year, 1);

      expect(p.first.start, DateTime(2020));
      expect(p.last.start, DateTime(2025));
    });

    test('the window goes back until its oldest column holds the first data', () {
      int steps(TrendScale scale, List<MonthlyFlow> f) => maxTrendSteps(scale: scale, today: today, flows: f);

      expect(steps(TrendScale.month, flows), 25);
      expect(points(TrendScale.month, 25).first.start, DateTime(2024, 3));
      expect(steps(TrendScale.year, flows), 0);
      expect(steps(TrendScale.year, const [MonthlyFlow(month: '2018-06', income: 1, expense: 0, netChange: 1)]), 3);
      expect(steps(TrendScale.month, flows.sublist(2)), 2);
      expect(steps(TrendScale.month, flows.sublist(3)), 0);
      expect(steps(TrendScale.month, const []), 0);
    });
  });

  group('summaries', () {
    Transaction t(TransactionType type, int amount, {int fee = 0, int? category, DateTime? at}) => Transaction(
      id: 0,
      type: type,
      amount: amount,
      fee: fee,
      assetId: 1,
      toAssetId: type == TransactionType.transfer ? 2 : null,
      categoryId: category,
      dateTime: at ?? DateTime(2026, 9, 1),
    );

    test('period totals use money actually moved and skip transfers', () {
      final s = PeriodTotals.of([
        t(TransactionType.income, 10000, fee: 1000),
        t(TransactionType.expense, 2000, fee: 50),
        t(TransactionType.transfer, 5000, fee: 10),
      ]);

      expect(s.income, 9000);
      expect(s.expense, 2050);
      expect(s.net, 6950);
    });

    test('category breakdown is ranked with percentages', () {
      final rows = categoryBreakdown([
        t(TransactionType.expense, 3000, category: 1),
        t(TransactionType.expense, 1000, category: 2),
        t(TransactionType.expense, 1000, fee: 0, category: 1),
        t(TransactionType.income, 9999, category: 3),
      ], TransactionType.expense);

      expect(rows.map((r) => r.categoryId), [1, 2]);
      expect(rows.map((r) => r.total), [4000, 1000]);
      expect(rows.map((r) => r.percent), [80.0, 20.0]);
    });

    test('savings rate is the share of income kept, with none when nothing came in', () {
      expect(savingsRate(1000, 250), 75);
      expect(savingsRate(1000, 1500), -50);
      expect(savingsRate(0, 300), isNull);
      expect(savingsRate(-200, 0), isNull);
    });

    test('spending pace adds up expenses day by day through a month', () {
      final sep = Period.containing(PeriodKind.month, DateTime(2026, 9, 10));
      final pace = spendingPace([
        t(TransactionType.expense, 100, fee: 5, at: DateTime(2026, 9, 1, 8)),
        t(TransactionType.expense, 200, at: DateTime(2026, 9, 3, 23)),
        t(TransactionType.expense, -50, at: DateTime(2026, 9, 3, 9)),
        t(TransactionType.income, 9999, at: DateTime(2026, 9, 2)),
        t(TransactionType.transfer, 9999, at: DateTime(2026, 9, 2)),
        t(TransactionType.expense, 9999, at: DateTime(2026, 10, 1)),
      ], sep);

      expect(pace.length, 30);
      expect(pace.take(4), [105, 105, 255, 255]);
      expect(pace.last, 255);
    });

    test('spending pace stops at today while the period is still running', () {
      final sep = Period.containing(PeriodKind.month, DateTime(2026, 9, 10));
      final pace = spendingPace(
        [t(TransactionType.expense, 100, at: DateTime(2026, 9, 2))],
        sep,
        today: DateTime(2026, 9, 4, 18),
      );

      expect(pace, [0, 100, 100, 100]);
      expect(spendingPace(const [], sep, today: DateTime(2026, 11, 1)).length, 30);
    });

    test('spending pace follows a salary-cycle month', () {
      final cycle = Period.containing(PeriodKind.month, DateTime(2026, 9, 10), monthStartDay: 25);
      final pace = spendingPace([
        t(TransactionType.expense, 100, at: DateTime(2026, 8, 25)),
        t(TransactionType.expense, 10, at: DateTime(2026, 9, 24)),
      ], cycle);

      expect(pace.length, 31);
      expect(pace.first, 100);
      expect(pace.last, 110);
    });

    test('spending pace through a year has one point per month', () {
      final year = Period.containing(PeriodKind.year, DateTime(2026, 5, 1));
      final pace = spendingPace(
        [
          t(TransactionType.expense, 100, at: DateTime(2026, 1, 31)),
          t(TransactionType.expense, 50, at: DateTime(2026, 3, 1)),
        ],
        year,
        today: DateTime(2026, 4, 2),
      );

      expect(pace, [100, 100, 150, 150]);
      expect(spendingPace(const [], year).length, 12);
    });

    test('spending so far is compared with the same day of the period before', () {
      final year = Period.containing(PeriodKind.year, DateTime(2026, 10, 3));
      final txns = [
        t(TransactionType.expense, 100, at: DateTime(2026, 10, 2)),
        t(TransactionType.expense, 7, at: DateTime(2026, 10, 30)),
        t(TransactionType.expense, 20, at: DateTime(2025, 10, 3, 23)),
        t(TransactionType.expense, 300, at: DateTime(2025, 10, 4)),
      ];

      expect(spendingSoFar(txns, year, DateTime(2026, 10, 3, 9)), (now: 100, before: 20));
      expect(spendingSoFar(txns, year, DateTime(2027, 1, 5)), (now: 107, before: 320));
    });

    test('a short month is compared with all of a longer one before it only once it ends', () {
      final mar = Period.containing(PeriodKind.month, DateTime(2026, 3, 1));
      final txns = [t(TransactionType.expense, 50, at: DateTime(2026, 2, 28))];

      expect(spendingSoFar(txns, mar, DateTime(2026, 3, 31)).before, 50);
      expect(spendingSoFar(txns, mar, DateTime(2026, 3, 27)).before, 0);
    });

    test('periods ending at one go back a step at a time, oldest first', () {
      final sep = Period.containing(PeriodKind.month, DateTime(2026, 9, 10));

      expect(periodsEnding(sep, 3).map((p) => p.start), [DateTime(2026, 7), DateTime(2026, 8), DateTime(2026, 9)]);
    });

    test('category history totals one category in each period', () {
      final periods = periodsEnding(Period.containing(PeriodKind.month, DateTime(2026, 9, 10)), 3);
      final txns = [
        t(TransactionType.expense, 100, fee: 5, category: 1, at: DateTime(2026, 7, 31)),
        t(TransactionType.expense, 300, category: 1, at: DateTime(2026, 9, 1)),
        t(TransactionType.expense, 999, category: 2, at: DateTime(2026, 9, 1)),
        t(TransactionType.income, 999, category: 1, at: DateTime(2026, 9, 1)),
        t(TransactionType.expense, 40, at: DateTime(2026, 8, 1)),
      ];

      expect(categoryHistory(txns, periods, TransactionType.expense, 1), [105, 0, 300]);
      expect(categoryHistory(txns, periods, TransactionType.expense, null), [0, 40, 0]);
    });

    test('groups transactions by day, newest first, with day totals', () {
      final days = groupByDay([
        t(TransactionType.expense, 100, at: DateTime(2026, 9, 1, 9)),
        t(TransactionType.income, 500, at: DateTime(2026, 9, 2, 8)),
        t(TransactionType.expense, 300, at: DateTime(2026, 9, 2, 20)),
      ]);

      expect(days.map((d) => d.date), [DateTime(2026, 9, 2), DateTime(2026, 9, 1)]);
      expect(days.first.totals.income, 500);
      expect(days.first.totals.expense, 300);
      expect(days.first.transactions.map((x) => x.amount), [300, 500]);
    });
  });
}
