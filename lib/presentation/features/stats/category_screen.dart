import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../domain/models/enums.dart';
import '../../../domain/models/transactions.dart';
import '../../../domain/services/calendar.dart';
import '../../../domain/services/money.dart';
import '../../../domain/services/reports.dart';
import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../widgets/charts.dart';
import '../../widgets/period_switcher.dart';
import '../transactions/transactions_screen.dart';
import 'stats_screen.dart';

const _historyColumns = 6;

typedef _HistoryRange = ({DateTime from, DateTime toExclusive, TransactionType type});

/// Entries of one type over the history window. Loaded only while a
/// category screen is open.
final _historyProvider = StreamProvider.autoDispose.family<List<Transaction>, _HistoryRange>(
  (ref, r) => ref
      .watch(repositoriesProvider)
      .transactions
      .watch(TransactionQuery(from: r.from, toExclusive: r.toExclusive, types: {r.type})),
);

/// One category: its total over the last six months or years, then its
/// entries in the period chosen on the Stats tab.
class CategoryScreen extends ConsumerStatefulWidget {
  const CategoryScreen({
    super.key,
    required this.title,
    required this.categoryId,
    required this.type,
    required this.period,
    required this.transactions,
  });

  final String title;
  final int? categoryId;
  final TransactionType type;
  final Period period;
  final List<Transaction> transactions;

  @override
  ConsumerState<CategoryScreen> createState() => _CategoryScreenState();
}

class _CategoryScreenState extends ConsumerState<CategoryScreen> {
  // A custom range has no natural steps to go back by, so it starts monthly.
  late PeriodKind _kind = widget.period.kind == PeriodKind.year ? PeriodKind.year : PeriodKind.month;

  @override
  Widget build(BuildContext context) {
    final last = Period.containing(
      _kind,
      switchAnchor(widget.period, ref.watch(clockProvider)()),
      monthStartDay: ref.watch(settingsProvider).monthStartDay,
    );
    final periods = periodsEnding(last, _historyColumns);
    final txns = ref
        .watch(_historyProvider((from: periods.first.start, toExclusive: last.endExclusive, type: widget.type)))
        .value;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Flexible(
                      child: Text(
                        'Last $_historyColumns ${_kind == PeriodKind.year ? 'years' : 'months'}',
                        style: Theme.of(context).textTheme.titleMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(right: statsMenuInset),
                      child: PeriodMenu<PeriodKind>(
                        options: const [(PeriodKind.month, 'Month'), (PeriodKind.year, 'Year')],
                        selected: _kind,
                        onSelected: (kind) => setState(() => _kind = kind),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                SizedBox(
                  height: 180,
                  child: txns == null
                      ? null
                      : _HistoryChart(
                          periods,
                          categoryHistory(txns, periods, widget.type, widget.categoryId),
                          widget.type == TransactionType.expense,
                          ref.watch(moneyFormatProvider),
                        ),
                ),
              ],
            ),
          ),
          for (final t in widget.transactions) TransactionTile(t, showDate: true),
        ],
      ),
    );
  }
}

class _HistoryChart extends StatelessWidget {
  const _HistoryChart(this.periods, this.totals, this.isExpense, this.money);

  final List<Period> periods;
  final List<int> totals;
  final bool isExpense;
  final MoneyFormat money;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    String short(Period p) => DateFormat(switch (p.kind) {
      PeriodKind.year => 'yyyy',
      _ when p.start.day == 1 => 'MMM',
      _ => 'd MMM',
    }).format(p.start);
    return BarChart(
      BarChartData(
        gridData: chartGrid(scheme),
        borderData: FlBorderData(show: false),
        titlesData: bottomTitles(context, (i) => short(periods[i])),
        barTouchData: barTooltip(
          scheme,
          (group, value, _) => '${periodLabel(periods[group.x])}\n${money.format(value.toInt())}',
        ),
        barGroups: [
          for (final (i, total) in totals.indexed)
            BarChartGroupData(
              x: i,
              barRods: [
                BarChartRodData(
                  toY: total.toDouble(),
                  color: isExpense ? scheme.series2 : scheme.series1,
                  width: 16,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
