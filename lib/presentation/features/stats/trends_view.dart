import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../domain/models/transactions.dart';
import '../../../domain/services/money.dart';
import '../../../domain/services/reports.dart';
import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../widgets/charts.dart';
import '../../widgets/common.dart';
import '../../widgets/period_switcher.dart';
import 'stats_screen.dart';

typedef _Window = ({TrendScale scale, int stepsBack});

/// Kept while the Stats tab is open, so the chosen window survives opening
/// another Stats section.
class _WindowController extends Notifier<_Window> {
  @override
  _Window build() => (scale: TrendScale.month, stepsBack: 0);

  void scale(TrendScale scale) => state = (scale: scale, stepsBack: 0);

  void shift(int stepsBack) => state = (scale: state.scale, stepsBack: stepsBack);
}

final trendWindowProvider = NotifierProvider.autoDispose<_WindowController, _Window>(_WindowController.new);

final _trendDataProvider = FutureProvider<({int netWorth, List<MonthlyFlow> flows})>(
  (ref) async => (
    netWorth: (await ref.watch(balanceSheetProvider.future)).netWorth,
    flows: await ref.watch(monthlyFlowsProvider.future),
  ),
);

String _short(TrendScale scale, DateTime d) => DateFormat(scale == TrendScale.month ? 'MMM' : 'yyyy').format(d);

String _long(TrendScale scale, DateTime d) => DateFormat(scale == TrendScale.month ? 'MMM yyyy' : 'yyyy').format(d);

String _range(TrendScale scale, List<TrendPoint> points) {
  final first = points.first.start;
  final last = points.last.start;
  final sameYear = scale == TrendScale.month && first.year == last.year;
  return '${sameYear ? _short(scale, first) : _long(scale, first)} – ${_long(scale, last)}';
}

/// Net worth, income/expense and savings rate over six months or six years, paged one
/// month or year at a time.
class TrendsView extends ConsumerWidget {
  const TrendsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(_trendDataProvider).value;
    final window = ref.watch(trendWindowProvider);
    final today = ref.watch(clockProvider)();
    final money = ref.watch(moneyFormatProvider);
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    if (data == null) return const SizedBox();
    final scale = window.scale;
    final maxSteps = maxTrendSteps(scale: scale, today: today, flows: data.flows);
    // Deleting old entries can leave the window past the oldest data.
    final steps = window.stepsBack.clamp(0, maxSteps);
    final points = trendPoints(
      scale: scale,
      today: today,
      stepsBack: steps,
      currentNetWorth: data.netWorth,
      flows: data.flows,
    );
    final controller = ref.read(trendWindowProvider.notifier);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Laid out like the period bar of the other sections.
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Previous',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.chevron_left),
                      onPressed: steps < maxSteps ? () => controller.shift(steps + 1) : null,
                    ),
                    Flexible(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text(
                          _range(scale, points),
                          style: text.titleMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Next',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.chevron_right),
                      onPressed: steps > 0 ? () => controller.shift(steps - 1) : null,
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: statsMenuInset),
                child: PeriodMenu<TrendScale>(
                  options: const [(TrendScale.month, 'Month'), (TrendScale.year, 'Year')],
                  selected: scale,
                  onSelected: controller.scale,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text('Net worth', style: text.titleMedium),
          const SizedBox(height: 12),
          SizedBox(height: 200, child: _NetWorthChart(points, scale, money)),
          const SizedBox(height: 16),
          Text('Income and expense', style: text.titleMedium),
          const SizedBox(height: 8),
          ChartLegend([('Income', scheme.series1), ('Expense', scheme.series2)]),
          const SizedBox(height: 12),
          SizedBox(height: 200, child: _FlowChart(points, scale, money)),
          const SizedBox(height: 16),
          Text('Savings rate', style: text.titleMedium),
          const SizedBox(height: 12),
          SizedBox(height: 200, child: _SavingsChart(points, scale)),
          const SizedBox(height: 16),
          _TrendTable(points, scale, money),
        ],
      ),
    );
  }
}

FlTitlesData _titles(
  BuildContext context,
  List<TrendPoint> points,
  TrendScale scale,
  AxisScale axis,
  String Function(double value) left,
) => chartTitles(context, bottom: (i) => _short(scale, points[i].start), interval: 1, scale: axis, left: left);

String Function(double value) _moneyLabel(MoneyFormat money, AxisScale axis) =>
    (v) => money.compact(v.round(), step: axis.step.round());

LineChartBarData _line(List<FlSpot> spots, ColorScheme scheme) => LineChartBarData(
  spots: spots,
  color: scheme.series1,
  barWidth: 2,
  dotData: FlDotData(
    getDotPainter: (_, _, _, _) =>
        FlDotCirclePainter(radius: 4, color: scheme.series1, strokeWidth: 2, strokeColor: scheme.surface),
  ),
);

class _NetWorthChart extends StatelessWidget {
  const _NetWorthChart(this.points, this.scale, this.money);

  final List<TrendPoint> points;
  final TrendScale scale;
  final MoneyFormat money;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final axis = AxisScale.of([for (final p in points) p.netWorth], minStep: money.unit, fromZero: false);
    return LineChart(
      LineChartData(
        minY: axis.min,
        maxY: axis.max,
        gridData: chartGrid(scheme, axis),
        borderData: FlBorderData(show: false),
        titlesData: _titles(context, points, scale, axis, _moneyLabel(money, axis)),
        lineTouchData: lineTooltip(
          scheme,
          (s) => '${_long(scale, points[s.x.toInt()].start)}\n${money.format(points[s.x.toInt()].netWorth)}',
        ),
        lineBarsData: [
          _line([for (final (i, p) in points.indexed) FlSpot(i.toDouble(), p.netWorth.toDouble())], scheme),
        ],
      ),
    );
  }
}

class _FlowChart extends StatelessWidget {
  const _FlowChart(this.points, this.scale, this.money);

  final List<TrendPoint> points;
  final TrendScale scale;
  final MoneyFormat money;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    BarChartRodData rod(int value, Color color) => BarChartRodData(
      toY: value.toDouble(),
      color: color,
      width: 10,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
    );
    final axis = AxisScale.of([
      for (final p in points) ...[p.income, p.expense],
    ], minStep: money.unit);
    return BarChart(
      BarChartData(
        minY: axis.min,
        maxY: axis.max,
        gridData: chartGrid(scheme, axis),
        borderData: FlBorderData(show: false),
        titlesData: _titles(context, points, scale, axis, _moneyLabel(money, axis)),
        barTouchData: barTooltip(
          scheme,
          (_, value, rodIndex) => '${rodIndex == 0 ? 'Income' : 'Expense'}\n${money.format(value.toInt())}',
        ),
        barGroups: [
          for (final (i, p) in points.indexed)
            BarChartGroupData(
              x: i,
              barsSpace: 2,
              barRods: [rod(p.income, scheme.series1), rod(p.expense, scheme.series2)],
            ),
        ],
      ),
    );
  }
}

/// Share of income kept. A period that lost more than its whole income is
/// drawn at −100% so one bad month does not flatten the rest; the tooltip
/// keeps the real figure. A period with no income has no point.
class _SavingsChart extends StatelessWidget {
  const _SavingsChart(this.points, this.scale);

  final List<TrendPoint> points;
  final TrendScale scale;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rates = [for (final p in points) savingsRate(p.income, p.expense)];
    double drawn(double rate) => math.max(rate, -100);
    final axis = AxisScale.of([100, for (final r in rates.whereType<double>()) drawn(r)]);
    return LineChart(
      LineChartData(
        minY: axis.min,
        maxY: axis.max,
        gridData: chartGrid(scheme, axis),
        borderData: FlBorderData(show: false),
        titlesData: _titles(context, points, scale, axis, (v) => '${v.round()}%'),
        extraLinesData: ExtraLinesData(horizontalLines: [HorizontalLine(y: 0, color: scheme.outline, strokeWidth: 1)]),
        lineTouchData: lineTooltip(
          scheme,
          (s) => '${_long(scale, points[s.x.toInt()].start)}\n${rates[s.x.toInt()]!.round()}%',
        ),
        lineBarsData: [
          _line([
            for (final (i, r) in rates.indexed) r == null ? FlSpot.nullSpot : FlSpot(i.toDouble(), drawn(r)),
          ], scheme),
        ],
      ),
    );
  }
}

class _TrendTable extends StatelessWidget {
  const _TrendTable(this.points, this.scale, this.money);

  final List<TrendPoint> points;
  final TrendScale scale;
  final MoneyFormat money;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (final p in points.reversed)
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(_long(scale, p.start)),
          subtitle: Text(
            [
              'In ${money.format(p.income)}',
              'Out ${money.format(p.expense)}',
              if (savingsRate(p.income, p.expense) case final rate?) 'Kept ${rate.round()}%',
            ].join(' · '),
          ),
          trailing: MoneyText(p.netWorth, tone: MoneyTone.signed),
        ),
    ],
  );
}
