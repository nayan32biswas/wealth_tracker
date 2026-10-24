import '../models/accounts.dart';
import '../models/enums.dart';
import '../models/transactions.dart';
import 'calendar.dart';

class AccountBalance {
  const AccountBalance(this.asset, this.balance);

  final Asset asset;
  final int balance;
}

class GroupBalance {
  const GroupBalance(this.group, this.accounts);

  final AssetGroup group;
  final List<AccountBalance> accounts;

  int get total => accounts.fold(0, (sum, a) => sum + a.balance);
}

/// Balances are signed: a liability account with a debt has a negative
/// balance, so net worth is simply the sum of every account.
class BalanceSheet {
  BalanceSheet._(this.groups);

  factory BalanceSheet.from(List<AssetGroup> groups, List<Asset> assets, Map<int, int> deltas) => BalanceSheet._([
    for (final g in groups)
      GroupBalance(g, [
        for (final a in assets.where((a) => a.groupId == g.id))
          AccountBalance(a, a.initialBalance + (deltas[a.id] ?? 0)),
      ]),
  ]);

  final List<GroupBalance> groups;

  /// Null once the account has been removed.
  int? balanceOf(int assetId) =>
      groups.expand((g) => g.accounts).where((a) => a.asset.id == assetId).firstOrNull?.balance;

  int get assets => groups.where((g) => !g.group.isLiability).fold(0, (sum, g) => sum + g.total);

  /// Shown as the amount owed, so a debt reads as a positive number.
  int get liabilities => -groups.where((g) => g.group.isLiability).fold(0, (sum, g) => sum + g.total);

  int get netWorth => assets - liabilities;
}

/// Net worth at the end of each of [months] (`YYYY-MM`, ascending).
/// Worked back from today's net worth, so removed accounts and opening
/// balances never skew the history.
List<int> netWorthTrend({required int current, required List<MonthlyFlow> flows, required List<String> months}) => [
  for (final m in months) flows.where((f) => f.month.compareTo(m) > 0).fold(current, (sum, f) => sum - f.netChange),
];

enum TrendScale { month, year }

/// One column of the Trends charts.
class TrendPoint {
  const TrendPoint(this.start, this.netWorth, this.income, this.expense);

  /// First day of the month or year.
  final DateTime start;

  /// At the end of the month or year.
  final int netWorth;
  final int income;
  final int expense;
}

const trendColumns = 6;

/// The [trendColumns] months or years ending [stepsBack] steps before the
/// one that holds [today].
List<TrendPoint> trendPoints({
  required TrendScale scale,
  required DateTime today,
  required int stepsBack,
  required int currentNetWorth,
  required List<MonthlyFlow> flows,
}) {
  final end = _periodIndex(scale, today) - stepsBack;
  final starts = [for (var i = end - trendColumns + 1; i <= end; i++) _periodStart(scale, i)];
  final worth = netWorthTrend(
    current: currentNetWorth,
    flows: flows,
    months: [for (final s in starts) monthKey(scale == TrendScale.month ? s : DateTime(s.year, 12))],
  );
  String key(String month) => scale == TrendScale.month ? month : month.substring(0, 4);
  final income = <String, int>{};
  final expense = <String, int>{};
  for (final f in flows) {
    income.update(key(f.month), (v) => v + f.income, ifAbsent: () => f.income);
    expense.update(key(f.month), (v) => v + f.expense, ifAbsent: () => f.expense);
  }
  return [
    for (final (i, s) in starts.indexed)
      TrendPoint(s, worth[i], income[key(monthKey(s))] ?? 0, expense[key(monthKey(s))] ?? 0),
  ];
}

/// How far back the window can go: until its oldest column holds the first
/// month with any entries, so it never pages into empty history.
int maxTrendSteps({required TrendScale scale, required DateTime today, required List<MonthlyFlow> flows}) {
  if (flows.isEmpty) return 0;
  final first = flows.map((f) => f.month).reduce((a, b) => a.compareTo(b) <= 0 ? a : b);
  final oldest = _periodIndex(scale, today) - trendColumns + 1;
  final steps = oldest - _periodIndex(scale, parseDateKey('$first-01'));
  return steps > 0 ? steps : 0;
}

int _periodIndex(TrendScale scale, DateTime d) => scale == TrendScale.month ? d.year * 12 + d.month - 1 : d.year;

DateTime _periodStart(TrendScale scale, int index) =>
    scale == TrendScale.month ? DateTime(index ~/ 12, index % 12 + 1) : DateTime(index);

/// Transfers move money between the user's own accounts, so they are not
/// income or expense.
class PeriodTotals {
  const PeriodTotals(this.income, this.expense);

  factory PeriodTotals.of(Iterable<Transaction> txns) {
    var income = 0;
    var expense = 0;
    for (final t in txns) {
      if (t.type == TransactionType.income) income += t.total;
      if (t.type == TransactionType.expense) expense += t.total;
    }
    return PeriodTotals(income, expense);
  }

  final int income;
  final int expense;

  int get net => income - expense;
}

/// Money into and out of one account. Unlike [PeriodTotals], transfers
/// count, so [net] is how much the balance moved. A transfer fee comes off
/// the source; the target gets the plain amount.
class AccountTotals {
  const AccountTotals(this.inflow, this.outflow);

  factory AccountTotals.of(Iterable<Transaction> txns, int accountId) {
    var inflow = 0;
    var outflow = 0;
    for (final t in txns) {
      if (t.type == TransactionType.transfer && t.toAssetId == accountId) inflow += t.amount;
      if (t.assetId != accountId) continue;
      if (t.type == TransactionType.income) {
        inflow += t.total;
      } else {
        outflow += t.total;
      }
    }
    return AccountTotals(inflow, outflow);
  }

  final int inflow;
  final int outflow;

  int get net => inflow - outflow;
}

class CategoryShare {
  const CategoryShare(this.categoryId, this.total, this.percent);

  final int? categoryId;
  final int total;
  final double percent;
}

List<CategoryShare> categoryBreakdown(Iterable<Transaction> txns, TransactionType type) {
  final totals = <int?, int>{};
  for (final t in txns.where((t) => t.type == type)) {
    totals[t.categoryId] = (totals[t.categoryId] ?? 0) + t.total;
  }
  final sum = totals.values.fold(0, (a, b) => a + b);
  return [for (final e in totals.entries) CategoryShare(e.key, e.value, sum == 0 ? 0 : e.value * 100 / sum)]
    ..sort((a, b) => b.total.compareTo(a.total));
}

/// Percent of income kept after expenses; below zero when more went out than
/// came in. None when nothing came in, as a share of zero means nothing.
double? savingsRate(int income, int expense) => income <= 0 ? null : (income - expense) * 100 / income;

/// Money spent so far at the end of each day of [period], or of each month
/// when it is a year. While [today] falls inside the period the list stops
/// at today, so the line ends where the period has got to.
List<int> spendingPace(Iterable<Transaction> txns, Period period, {DateTime? today}) {
  final byMonth = period.kind == PeriodKind.year;
  int step(DateTime d) =>
      byMonth ? (d.year - period.start.year) * 12 + d.month - period.start.month : _calendarDays(period.start, d);
  final running = today != null && !today.isBefore(period.start) && today.isBefore(period.endExclusive);
  final spent = List.filled(step(running ? today : period.lastDay) + 1, 0);
  for (final t in txns.where((t) => t.type == TransactionType.expense)) {
    final i = step(t.dateTime);
    if (i >= 0 && i < spent.length) spent[i] += t.total;
  }
  for (var i = 1; i < spent.length; i++) {
    spent[i] += spent[i - 1];
  }
  return spent;
}

/// Spent in [period] up to the end of [today], and in the period before up
/// to the same number of days in, so a few days of October are not set
/// against all of last October. Once [period] is over, both are whole.
({int now, int before}) spendingSoFar(Iterable<Transaction> txns, Period period, DateTime today) {
  final before = period.previous();
  final running = !today.isBefore(period.start) && today.isBefore(period.endExclusive);
  final days = _calendarDays(period.start, today) + 1;
  DateTime cut(Period p) {
    final end = DateTime(p.start.year, p.start.month, p.start.day + days);
    return running && end.isBefore(p.endExclusive) ? end : p.endExclusive;
  }

  int spent(Period p) => txns
      .where((t) => t.type == TransactionType.expense && !t.dateTime.isBefore(p.start) && t.dateTime.isBefore(cut(p)))
      .fold(0, (sum, t) => sum + t.total);
  return (now: spent(period), before: spent(before));
}

// Counted on UTC dates: a local day can be 23 or 25 hours long when
// daylight saving starts or ends.
int _calendarDays(DateTime from, DateTime to) =>
    DateTime.utc(to.year, to.month, to.day).difference(DateTime.utc(from.year, from.month, from.day)).inDays;

/// [count] periods ending with [last], oldest first.
List<Period> periodsEnding(Period last, int count) {
  final periods = [last];
  while (periods.length < count) {
    periods.insert(0, periods.first.previous());
  }
  return periods;
}

/// What one category came to in each of [periods]. A null [categoryId] is
/// the entries without a category.
List<int> categoryHistory(Iterable<Transaction> txns, List<Period> periods, TransactionType type, int? categoryId) => [
  for (final p in periods)
    txns
        .where(
          (t) =>
              t.type == type &&
              t.categoryId == categoryId &&
              !t.dateTime.isBefore(p.start) &&
              t.dateTime.isBefore(p.endExclusive),
        )
        .fold(0, (sum, t) => sum + t.total),
];

class DayGroup {
  const DayGroup(this.date, this.transactions);

  final DateTime date;
  final List<Transaction> transactions;

  PeriodTotals get totals => PeriodTotals.of(transactions);
}

List<DayGroup> groupByDay(Iterable<Transaction> txns) {
  final byDay = <DateTime, List<Transaction>>{};
  for (final t in txns) {
    byDay.putIfAbsent(dateOnly(t.dateTime), () => []).add(t);
  }
  return [
    for (final day in byDay.keys.toList()..sort((a, b) => b.compareTo(a)))
      DayGroup(day, byDay[day]!..sort((a, b) => b.dateTime.compareTo(a.dateTime))),
  ];
}
