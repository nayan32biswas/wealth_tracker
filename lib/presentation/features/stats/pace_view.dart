import 'dart:math' as math;

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
import '../../widgets/common.dart';
import '../../widgets/period_switcher.dart';
import 'stats_screen.dart';

/// Expenses of the Stats period and the one before it. Dropped once the
/// section closes, so a closed section re-runs nothing after each save.
final paceTransactionsProvider = StreamProvider.autoDispose<List<Transaction>>((ref) {
  final p = ref.watch(statsPeriodProvider);
  return ref
      .watch(repositoriesProvider)
      .transactions
      .watch(
        TransactionQuery(from: p.previous().start, toExclusive: p.endExclusive, types: const {TransactionType.expense}),
      );
});

/// Money spent so far in this period against the period before, day by
/// day for a month and month by month for a year.
class PaceView extends ConsumerWidget {
  const PaceView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final period = ref.watch(statsPeriodProvider);
    final txns = ref.watch(paceTransactionsProvider).value;
    final today = ref.watch(clockProvider)();
    final money = ref.watch(moneyFormatProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PeriodBar(statsPeriodProvider, menuInset: statsMenuInset),
          if (txns != null) ...[const SizedBox(height: 24), _PaceSummary(txns, period, today, money)],
        ],
      ),
    );
  }
}

class _PaceSummary extends StatelessWidget {
  const _PaceSummary(this.txns, this.period, this.today, this.money);

  final List<Transaction> txns;
  final Period period;
  final DateTime today;
  final MoneyFormat money;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final before = period.previous();
    final names = [periodLabel(period), periodLabel(before)];
    final running = !today.isBefore(period.start) && today.isBefore(period.endExclusive);
    final now = spendingPace(txns, period, today: today);
    final then = spendingPace(txns, before);
    final soFar = spendingSoFar(txns, period, today);
    final diff = soFar.now - soFar.before;
    final compared = diff == 0
        ? 'Same as ${names[1]}'
        : '${money.format(diff.abs())} ${diff > 0 ? 'more' : 'less'} than ${names[1]}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(running ? 'Spent so far' : 'Spent', style: text.labelLarge),
        MoneyText(soFar.now, style: text.headlineMedium),
        Text(running ? '$compared by this point' : compared, style: text.bodyMedium),
        const SizedBox(height: 16),
        ChartLegend([(names[0], scheme.series2), (names[1], scheme.outline)], lines: true),
        const SizedBox(height: 12),
        SizedBox(height: 200, child: _PaceChart(now, then, period, names, money)),
      ],
    );
  }
}

class _PaceChart extends StatelessWidget {
  const _PaceChart(this.now, this.then, this.period, this.names, this.money);

  final List<int> now;
  final List<int> then;
  final Period period;
  final List<String> names;
  final MoneyFormat money;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final byMonth = period.kind == PeriodKind.year;
    final start = period.start;
    String step(int i) => byMonth
        ? DateFormat('MMM').format(DateTime(start.year, start.month + i))
        : DateFormat('d').format(DateTime(start.year, start.month, start.day + i));
    LineChartBarData line(List<int> values, Color color) => LineChartBarData(
      spots: [for (final (i, v) in values.indexed) FlSpot(i.toDouble(), v.toDouble())],
      color: color,
      barWidth: 2,
      dotData: const FlDotData(show: false),
    );
    return LineChart(
      LineChartData(
        minX: 0,
        maxX: (math.max(now.length, then.length) - 1).toDouble(),
        gridData: chartGrid(scheme),
        borderData: FlBorderData(show: false),
        // The chart also labels the last point, which can crowd the one before it.
        titlesData: bottomTitles(
          context,
          (i) => i % (byMonth ? 3 : 7) != 0 ? null : step(i),
          interval: byMonth ? 3 : 7,
        ),
        lineTouchData: lineTooltip(scheme, (s) => '${names[s.barIndex]}\n${money.format(s.y.toInt())}'),
        lineBarsData: [line(now, scheme.series2), line(then, scheme.outline)],
      ),
    );
  }
}
